import AVFoundation
import Foundation
import ScreenCaptureKit

public enum RecorderError: Error, LocalizedError, CustomStringConvertible {
    case unsupportedOutputType
    case streamStopped(Error)
    /// The stream stopped when an audio device changed, and could not be started again.
    /// Everything up to there is written; the recording ends rather than fails.
    case deviceChangeEnded(Error)

    public var description: String {
        switch self {
        case .unsupportedOutputType: "ScreenCaptureKit delivered an unknown output type."
        case .streamStopped(let error): "Capture stopped early: \(error.localizedDescription)"
        case .deviceChangeEnded(let error):
            "An audio device changed and capture could not be started again: \(error.localizedDescription)"
        }
    }

    public var errorDescription: String? { description }
}

public struct RecordingSummary: Sendable {
    public let plan: OutputPlan
    public let screenFrames: Int
    public let systemAudioSamples: Int
    public let microphoneSamples: Int
    public let droppedSamples: Int
    public let systemAudioPeak: Float
    public let microphonePeak: Float
    /// Why capture ended by itself, when it did. Nil for an ordinary stop.
    public let endedEarly: String?
    /// No screen track was asked for, so its absence is not a shortfall.
    public var audioOnly = false
    /// When each output's buffers were stamped and arrived, and the devices in use.
    public var timing: CaptureTiming?

    public func peak(for track: AudioTrack) -> Float {
        switch track {
        case .systemAudio: systemAudioPeak
        case .microphone: microphonePeak
        }
    }

    public func samples(for track: AudioTrack) -> Int {
        switch track {
        case .systemAudio: systemAudioSamples
        case .microphone: microphoneSamples
        }
    }
}

/// A snapshot safe to read from another thread while capture is running.
public struct RecordingProgress: Sendable {
    public let screenFrames: Int
    public let droppedSamples: Int
}

/// A few dropped buffers among thousands is ordinary encoder jitter, and saying so
/// only teaches people to distrust the summary. Half a percent is a real shortfall.
public enum DropRate {
    public static func worthReporting(_ dropped: Int, of captured: Int) -> Bool {
        dropped > 0 && dropped * 200 > captured
    }
}

/// Drives one SCStream and fans its three output types into three files — two when the
/// recording is audio only.
///
/// Every stream output shares a single serial queue, so the writer table and the
/// session clock need no further locking.
///
/// The session clock starts at the first buffer that is *written*, whatever its output,
/// and the timeline anchor the participant monitor reads moves only with written
/// buffers. An audio-only recording discards its screen frames before either is touched
/// (see `accepts`), so its clock starts at the first audio buffer and the two audio
/// tracks and the participant times share it exactly as they share it with video.
///
/// Devices changing mid-call are followed without restarting anything the writers own
/// (`MicrophoneRoute`): the microphone moves with the default input, or off a device that
/// disappeared, through `SCStream.updateConfiguration`; and the stream, if a change stopped
/// it, is started again with the same outputs on the same queue. The writers, the session
/// clock and the files carry on, and a gap is written as silence (`TrackWriter`). That is
/// decided on a second queue, `devices`, which owns the stream and the route and touches
/// nothing the writers own, so the capture queue never waits on a device.
public final class Recorder: NSObject {
    private let options: CaptureOptions
    private let target: ResolvedTarget
    private let plan: OutputPlan
    private let queue = DispatchQueue(label: "ro.qlan.anyrec.capture")

    public let levels = LevelMonitor()

    private var writers: [SCStreamOutputType: TrackWriter] = [:]
    private var sessionStart: CMTime?
    private var timelineAnchor: (seconds: TimeInterval, uptime: TimeInterval)?
    private var failure: Error?
    private var streamFailure: Error?
    private var timing = CaptureTiming()
    /// The last microphone buffer: when it arrived and its rate. How a switch is checked.
    private var lastMicrophone: (arrival: Double, rate: Double)?

    /// Owned by `devices`.
    private let devices = DispatchQueue(label: "ro.qlan.anyrec.devices")
    private var stream: SCStream?
    private var route: MicrophoneRoute?
    private lazy var watch = DeviceWatch(queue: devices)
    private var stopping = false
    private var pendingUpdate: DispatchWorkItem?
    private var restart: Task<Void, Never>?
    private var restarts = 0
    /// Host time of the last change followed.
    private var lastChange: Double?
    /// Each device as last described, so one that has gone can still be named.
    private var described: [String: CaptureTiming.Device] = [:]

    public var captureEnded: Bool { queue.sync { streamFailure != nil } }

    var timelineTime: TimeInterval? {
        queue.sync {
            guard let anchor = timelineAnchor else { return nil }
            let age = ProcessInfo.processInfo.systemUptime - anchor.uptime
            return age <= 1.5 ? anchor.seconds + age : nil
        }
    }

    public init(options: CaptureOptions, target: ResolvedTarget, plan: OutputPlan) {
        self.options = options
        self.target = target
        self.plan = plan
    }

    public func start() async throws {
        let facts = Self.facts()
        let choice: MicrophoneRoute.Choice = options.followsDefaultMicrophone
            ? .followsDefault : options.microphoneDeviceID.map(MicrophoneRoute.Choice.pinned) ?? .followsDefault
        let route = MicrophoneRoute(choice: choice, facts: facts, recordsRaw: options.captureMicrophone)
        let stream = try makeStream(microphone: route.raw)
        try await stream.startCapture()
        noteDevices(microphone: route.raw)
        devices.sync {
            self.stream = stream
            self.route = route
            watch.start { [weak self] in self?.scheduleUpdate() }
        }
    }

    /// A stream with this recorder's outputs, all on the one capture queue, recording the
    /// microphone from `microphone`.
    private func makeStream(microphone: String?, withMicrophone: Bool = true) throws -> SCStream {
        let configuration = makeConfiguration(microphone: microphone)
        configuration.captureMicrophone = options.captureMicrophone && withMicrophone
        let stream = SCStream(filter: target.filter, configuration: configuration, delegate: self)
        /// Added with video off too: without a screen output ScreenCaptureKit still renders
        /// frames and logs every one it has nowhere to send. With one, they arrive at the
        /// configuration's two pixels and one frame a second and are dropped in `accepts`.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if configuration.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        return stream
    }

    /// The devices as they stand when capture starts: the default output, the default
    /// input, and the microphone recorded when it is another device.
    private func noteDevices(microphone uid: String?) {
        let output = AudioDeviceFacts.defaultOutput(), input = AudioDeviceFacts.defaultInput()
        let microphone = uid.flatMap { uid in uid == input?.uid ? nil : AudioDeviceFacts.input(uid: uid) }
        devices.sync {
            for device in [output, input, microphone].compactMap({ $0 }) { described[device.uid] = device }
        }
        queue.sync {
            timing.output = output
            timing.input = input
            timing.microphone = microphone
        }
    }

    static func facts() -> MicrophoneRoute.Facts {
        MicrophoneRoute.Facts(defaultInput: AudioDeviceFacts.defaultInputUID(), inputs: AudioDeviceFacts.inputUIDs(),
                              defaultOutput: AudioDeviceFacts.defaultOutputUID())
    }

    static let mostRestarts = 5
    /// Devices announce a change as several notifications in a row — the device list, then
    /// the default — so they are read once things have settled.
    static let settle: TimeInterval = 0.3
    /// How long after a switch the microphone has to be delivering from the new device.
    static let switchCheck: TimeInterval = 2.5
    /// A stream that stops within this of a device change stopped because of it.
    static let changeWindow: TimeInterval = 10

    /// On `devices`.
    private func scheduleUpdate() {
        guard !stopping else { return }
        pendingUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.followDevices() }
        pendingUpdate = work
        devices.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    /// Reads the devices and moves the microphone to where `MicrophoneRoute` says. On
    /// `devices`.
    private func followDevices() {
        guard !stopping, restart == nil, var route, let stream else { return }
        guard let change = route.update(Self.facts()) else { return }
        let observed = CaptureTiming.now()
        lastChange = observed
        let from = describe(change.input?.from), to = describe(change.input?.to)
        let outputs = (describe(change.output?.from, output: true), describe(change.output?.to, output: true))
        let problems: [String] = []
        self.route = route
        let fact = { (problems: [String]) in
            CaptureTiming.DeviceChange(
                at: observed, reason: change.reason, from: from, to: to, outputFrom: outputs.0,
                outputTo: outputs.1, affected: change.affected, problem: problems.isEmpty ? nil : problems.joined(separator: "; "))
        }
        guard change.switchRaw, let device = change.input?.to else { return record(fact(problems)) }
        let before = queue.sync { lastMicrophone }
        switchMicrophone(stream, to: device) { [weak self] problem in
            guard let self else { return }
            self.devices.async {
                self.record(fact(problems + (problem.map { ["microphone: " + $0] } ?? [])))
                self.checkSwitch(to: device, before: before, at: observed)
            }
        }
    }

    /// Points ScreenCaptureKit's microphone at `device` on the running stream. Nothing in
    /// the SDK limits which properties `updateConfiguration` may change, and changing it
    /// in place leaves the stream, the writers and the clock untouched. If the update is
    /// refused, microphone capture is turned off and on again with the new device; if that
    /// is refused too, the stream is started again (`checkSwitch`).
    private func switchMicrophone(_ stream: SCStream, to device: String, completion: @escaping (String?) -> Void) {
        let configuration = makeConfiguration(microphone: device)
        stream.updateConfiguration(configuration) { [weak self] error in
            guard let self, let error else { return completion(nil) }
            let off = self.makeConfiguration(microphone: device)
            off.captureMicrophone = false
            stream.updateConfiguration(off) { _ in
                stream.updateConfiguration(configuration) { again in
                    completion(again.map { "updateConfiguration refused the new device (\(error.localizedDescription); \($0.localizedDescription))" })
                }
            }
        }
    }

    /// Whether the microphone really moved. ScreenCaptureKit delivers a microphone in its
    /// device's own format, so a device of another rate shows in the buffers; and a
    /// microphone that delivers nothing for seconds after a switch is stuck on a device
    /// that has gone. Either way the stream is started again on the new device, which
    /// costs a moment of silence in every track and nothing else.
    private func checkSwitch(to device: String, before: (arrival: Double, rate: Double)?, at observed: Double) {
        /// A microphone that was delivering nothing before the switch says nothing by
        /// delivering nothing after it.
        guard let before else { return }
        let expected = describe(device)?.sampleRate
        devices.asyncAfter(deadline: .now() + Self.switchCheck) { [weak self] in
            guard let self, !self.stopping, self.restart == nil, self.route?.raw == device else { return }
            let last = self.queue.sync { self.lastMicrophone }
            let stalled = last.map { CaptureTiming.now() - $0.arrival > Self.switchCheck - 0.5 } ?? true
            let unmoved = Self.unmoved(before: before.rate, after: last?.rate, expected: expected)
            guard stalled || unmoved else { return }
            self.restartStream(because: stalled ? "the microphone delivered nothing after switching devices"
                                                : "the microphone was still in the old device's format after switching")
        }
    }

    /// True when the buffers say the microphone is still on the old device: the new one
    /// runs at another rate and the buffers have not changed to it.
    static func unmoved(before: Double?, after: Double?, expected: Double?) -> Bool {
        guard let before, let after, let expected, expected > 0, expected != before else { return false }
        return after == before
    }

    /// Starts the stream again with the same outputs on the same queue, recording the
    /// microphone from the route's device; without the microphone if that will not start.
    /// The writers, the session clock and the timeline carry on, and the gap is written as
    /// silence. On `devices`.
    private func restartStream(because reason: String, error: Error? = nil) {
        guard !stopping, restart == nil else { return }
        restarts += 1
        /// The device as things stand now: the one the route was on may be what went.
        let old = stream
        let device = route.flatMap { MicrophoneRoute.target(for: $0.choice, facts: Self.facts(), current: $0.raw) }
        let observed = CaptureTiming.now()
        lastChange = observed
        guard restarts <= Self.mostRestarts else {
            return endCapture(error ?? RecorderError.unsupportedOutputType, reason: "restarted too often")
        }
        let from = describe(device)
        restart = Task { [weak self] in
            guard let self else { return }
            try? await old?.stopCapture()
            var problems = [reason]
            var started: SCStream?
            for withMicrophone in [true, false] where started == nil {
                do {
                    let stream = try self.makeStream(microphone: device, withMicrophone: withMicrophone)
                    try await stream.startCapture()
                    started = stream
                    if !withMicrophone { problems.append("started again without the microphone") }
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
            self.devices.sync {
                self.restart = nil
                self.record(CaptureTiming.DeviceChange(
                    at: observed, reason: .streamRestarted, from: from, to: from,
                    affected: [CaptureTiming.screen, CaptureTiming.systemAudio, CaptureTiming.microphoneStream],
                    problem: problems.joined(separator: "; ")))
                guard let started else {
                    return self.endCapture(error ?? RecorderError.unsupportedOutputType, reason: problems.joined(separator: "; "))
                }
                self.stream = started
                /// The route catches up with whatever moved, and the change is recorded
                /// like any other.
                self.scheduleUpdate()
            }
        }
    }

    /// Nothing more can be captured. Reported as the end of the recording, never a
    /// failure: everything written so far is whole.
    private func endCapture(_ error: Error, reason: String) {
        let ended = RecorderError.deviceChangeEnded(
            NSError(domain: "anyrec", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(error.localizedDescription) (\(reason))"]))
        queue.async { self.streamFailure = self.streamFailure ?? ended }
    }

    /// Appends a change to the timing facts, on the session clock. On `devices`.
    private func record(_ change: CaptureTiming.DeviceChange) {
        queue.async {
            let start = self.timing.sessionStart ?? change.at
            let fact = CaptureTiming.DeviceChange(
                at: max(0, change.at - start), reason: change.reason, from: change.from, to: change.to,
                outputFrom: change.outputFrom, outputTo: change.outputTo, affected: change.affected, problem: change.problem)
            self.timing.deviceChanges = (self.timing.deviceChanges ?? []) + [fact]
        }
    }

    /// A device as Core Audio describes it now, or as it was last described if it has
    /// gone. On `devices`.
    private func describe(_ uid: String?, output: Bool = false) -> CaptureTiming.Device? {
        guard let uid else { return nil }
        let device = output ? AudioDeviceFacts.output(uid: uid) : AudioDeviceFacts.input(uid: uid)
        if let device { described[uid] = device }
        return device ?? described[uid]
    }

    /// Whether a stream that stopped with `error` stopped because an audio device changed:
    /// the microphone it recorded has gone, or the devices changed moments before, or
    /// ScreenCaptureKit says its microphone failed. A window closing or sharing being
    /// stopped is the end of the recording, never this.
    static func stoppedByDeviceChange(_ error: Error, microphoneGone: Bool, changedRecently: Bool) -> Bool {
        guard endOfRecording(error) == nil else { return false }
        let error = error as NSError
        let microphoneFailed = error.domain == SCStreamError.errorDomain
            && error.code == SCStreamError.Code.failedToStartMicrophoneCapture.rawValue
        return microphoneGone || changedRecently || microphoneFailed
    }

    private func note(_ sample: CMSampleBuffer, arrival: Double, as stream: String) {
        let presentation = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        /// JSON has no NaN, and a buffer without a time says nothing about timing.
        guard presentation.isFinite, arrival.isFinite else { return }
        let duration = CMSampleBufferGetDuration(sample).seconds
        let frames = Double(CMSampleBufferGetNumSamples(sample))
        let asbd = CMSampleBufferGetFormatDescription(sample)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let rate = asbd?.mSampleRate ?? 0
        let length = duration.isFinite && duration > 0 ? duration : (rate > 0 ? frames / rate : 0)
        timing.streams[stream, default: .init()].note(
            .init(presentation: presentation, arrival: arrival, duration: length))
        if let asbd, rate > 0 {
            let at = sessionStart.map { max(0, presentation - $0.seconds) } ?? 0
            timing.streams[stream]?.noteFormat(.init(at: at, sampleRate: rate, channels: Int(asbd.mChannelsPerFrame)))
        }
        if stream == CaptureTiming.microphoneStream { lastMicrophone = (arrival, rate) }
    }

    @discardableResult
    public func stop() async throws -> RecordingSummary {
        /// No device change is followed from here on, and a restart under way is waited for,
        /// so the stream stopped is the one running and nothing writes after the finish.
        let running = devices.sync { () -> Task<Void, Never>? in
            stopping = true
            pendingUpdate?.cancel()
            watch.stop()
            return restart
        }
        await running?.value
        if let stream = devices.sync(execute: { stream }) {
            try? await stream.stopCapture()
        }
        devices.sync { stream = nil }
        let (tracks, error) = queue.sync { (writers, failure ?? streamFailure) }
        for track in tracks.values { await track.finish() }
        let capturedTiming = queue.sync { () -> CaptureTiming in
            for (type, track) in tracks where !track.gaps.isEmpty {
                timing.streams[Self.streamName(type)]?.gaps = track.gaps.map { .init(at: $0.at, seconds: $0.seconds) }
            }
            return self.timing
        }

        let ended = error.flatMap(Self.endOfRecording)
        if let error, ended == nil { throw RecorderError.streamStopped(error) }
        return RecordingSummary(
            plan: plan,
            screenFrames: tracks[.screen]?.samplesWritten ?? 0,
            systemAudioSamples: tracks[.audio]?.samplesWritten ?? 0,
            microphoneSamples: tracks[.microphone]?.samplesWritten ?? 0,
            droppedSamples: tracks.values.reduce(0) { $0 + $1.samplesDropped },
            systemAudioPeak: levels.sessionPeak(for: .systemAudio),
            microphonePeak: levels.sessionPeak(for: .microphone),
            endedEarly: ended,
            audioOnly: !options.recordsVideo,
            timing: capturedTiming
        )
    }

    /// A call ends by its window going away — Slack closes it — and the stream stops
    /// with nothing left to capture. Everything up to that point is already written
    /// and finalised, so this is reported rather than thrown. Thrown, it turned a
    /// finished 78-minute recording into an error message and skipped the summary,
    /// the merge and the offer to transcribe.
    static func endOfRecording(_ error: Error) -> String? {
        if case RecorderError.deviceChangeEnded = error {
            return "An audio device changed and capture could not be started again, so it stopped there."
        }
        let error = error as NSError
        guard error.domain == SCStreamError.errorDomain else { return nil }
        switch error.code {
        case SCStreamError.Code.noCaptureSource.rawValue:
            return "The window being recorded closed, so capture stopped there."
        case SCStreamError.Code.userStopped.rawValue:
            return "Screen sharing was stopped, so capture stopped there."
        default:
            return nil
        }
    }

    public func progress() -> RecordingProgress {
        queue.sync {
            RecordingProgress(
                screenFrames: writers[.screen]?.samplesWritten ?? 0,
                droppedSamples: writers.values.reduce(0) { $0 + $1.samplesDropped }
            )
        }
    }

    func makeConfiguration() -> SCStreamConfiguration {
        makeConfiguration(microphone: options.microphoneDeviceID)
    }

    func makeConfiguration(microphone: String?) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        if options.recordsVideo {
            config.width = target.width
            config.height = target.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
            config.queueDepth = 6
            config.showsCursor = options.showsCursor
        } else {
            /// The stream needs a picture to run, so it gets the cheapest one it accepts:
            /// a few pixels, once a second, and nothing that is never written.
            config.width = Self.audioOnlyFrame
            config.height = Self.audioOnlyFrame
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 3
            config.showsCursor = false
        }
        // Off, the output only scales down: shrink the window mid-call and the frame
        // keeps its size with the picture in one corner and black around the rest.
        // With the fixed window frame, this is also what fits a window of any shape and
        // size into it, as large as it goes with its proportions kept.
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = options.captureSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = options.captureMicrophone
        config.microphoneCaptureDeviceID = microphone
        return config
    }

    /// The side of the smallest picture an audio-only stream is given.
    static let audioOnlyFrame = 2

    /// Whether a buffer of this output is written at all. Nothing that is not written may
    /// start the session clock or move the timeline anchor: an audio-only recording's
    /// screen frames are refused here, before either is touched, and no screen writer
    /// is ever made for them.
    func accepts(_ type: SCStreamOutputType, complete: @autoclosure () -> Bool) -> Bool {
        guard type == .screen else { return true }
        return options.recordsVideo && complete()
    }

    private func writer(for type: SCStreamOutputType, buffer: CMSampleBuffer) throws -> TrackWriter {
        if let existing = writers[type] { return existing }

        let format = CMSampleBufferGetFormatDescription(buffer)
        let created: TrackWriter
        switch type {
        case .screen:
            /// `accepts` keeps screen buffers away when video is off; this is the backstop.
            guard options.recordsVideo else { throw RecorderError.unsupportedOutputType }
            created = try TrackWriter(
                url: plan.screen,
                kind: .video(
                    codec: options.codec.avCodecType,
                    width: target.width,
                    height: target.height
                ),
                formatHint: nil
            )
        case .audio:
            created = try TrackWriter(url: plan.systemAudio, kind: .audio, formatHint: format)
        case .microphone:
            created = try TrackWriter(url: plan.microphone, kind: .audio, formatHint: format)
        @unknown default:
            throw RecorderError.unsupportedOutputType
        }
        writers[type] = created
        return created
    }

    static func streamName(_ type: SCStreamOutputType) -> String {
        switch type {
        case .screen: CaptureTiming.screen
        case .audio: CaptureTiming.systemAudio
        case .microphone: CaptureTiming.microphoneStream
        @unknown default: "unknown"
        }
    }

    /// SCK emits idle and blank frames when nothing on screen changed; writing those
    /// would pad the video with duplicate frames and drift it out of sync with audio.
    private func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                buffer, createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}

extension Recorder: SCStreamOutput {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let arrival = CaptureTiming.now()
        guard accepts(type, complete: isCompleteFrame(sampleBuffer)) else { return }
        note(sampleBuffer, arrival: arrival, as: Self.streamName(type))

        if let track = AudioTrack(type), let level = AudioLevelMeter.measure(sampleBuffer) {
            levels.record(level, for: track)
        }

        do {
            let track = try writer(for: type, buffer: sampleBuffer)
            let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let start = sessionStart ?? presentation
            if sessionStart == nil { timing.sessionStart = start.seconds }
            sessionStart = start
            let seconds = CMTimeGetSeconds(presentation - start)
            if seconds.isFinite, seconds >= (timelineAnchor?.seconds ?? 0) {
                timelineAnchor = (seconds, ProcessInfo.processInfo.systemUptime)
            }
            track.append(sampleBuffer, sessionStart: start)
        } catch {
            failure = failure ?? error
        }
    }
}

extension AudioTrack {
    init?(_ type: SCStreamOutputType) {
        switch type {
        case .audio: self = .systemAudio
        case .microphone: self = .microphone
        default: return nil
        }
    }
}

extension Recorder: SCStreamDelegate {
    /// A stream stopped by a device change is started again; anything else ends capture
    /// as before, and `stop` decides whether that is the end of the recording or a failure.
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let restarted = devices.sync { () -> Bool in
            guard stream === self.stream, !stopping, let route else { return false }
            let inputs = AudioDeviceFacts.inputUIDs()
            let gone = route.recordsRaw && route.raw.map { !inputs.contains($0) } ?? false
            let recent = lastChange.map { CaptureTiming.now() - $0 < Self.changeWindow } ?? false
            guard Self.stoppedByDeviceChange(error, microphoneGone: gone, changedRecently: recent) else { return false }
            restartStream(because: "the stream stopped: " + error.localizedDescription, error: error)
            return true
        }
        if !restarted { queue.async { self.streamFailure = self.streamFailure ?? error } }
    }
}
