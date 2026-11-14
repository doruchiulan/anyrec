import AVFoundation
import Foundation
import ScreenCaptureKit

public enum RecorderError: Error, LocalizedError, CustomStringConvertible {
    case unsupportedOutputType
    case streamStopped(Error)

    public var description: String {
        switch self {
        case .unsupportedOutputType: "ScreenCaptureKit delivered an unknown output type."
        case .streamStopped(let error): "Capture stopped early: \(error.localizedDescription)"
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
public final class Recorder: NSObject {
    private let options: CaptureOptions
    private let target: ResolvedTarget
    private let plan: OutputPlan
    private let queue = DispatchQueue(label: "ro.qlan.anyrec.capture")

    public let levels = LevelMonitor()

    private var stream: SCStream?
    private var writers: [SCStreamOutputType: TrackWriter] = [:]
    private var sessionStart: CMTime?
    private var timelineAnchor: (seconds: TimeInterval, uptime: TimeInterval)?
    private var failure: Error?
    private var streamFailure: Error?

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
        let stream = SCStream(
            filter: target.filter, configuration: makeConfiguration(), delegate: self
        )
        /// Added with video off too: without a screen output ScreenCaptureKit still renders
        /// frames and logs every one it has nowhere to send. With one, they arrive at the
        /// configuration's two pixels and one frame a second and are dropped in `accepts`.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if options.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    @discardableResult
    public func stop() async throws -> RecordingSummary {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        let (tracks, error) = queue.sync { (writers, failure ?? streamFailure) }
        for track in tracks.values { await track.finish() }

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
            audioOnly: !options.recordsVideo
        )
    }

    /// A call ends by its window going away — Slack closes it — and the stream stops
    /// with nothing left to capture. Everything up to that point is already written
    /// and finalised, so this is reported rather than thrown. Thrown, it turned a
    /// finished 78-minute recording into an error message and skipped the summary,
    /// the merge and the offer to transcribe.
    static func endOfRecording(_ error: Error) -> String? {
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
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = options.captureSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = options.captureMicrophone
        config.microphoneCaptureDeviceID = options.microphoneDeviceID
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
        guard accepts(type, complete: isCompleteFrame(sampleBuffer)) else { return }

        if let track = AudioTrack(type), let level = AudioLevelMeter.measure(sampleBuffer) {
            levels.record(level, for: track)
        }

        do {
            let track = try writer(for: type, buffer: sampleBuffer)
            let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let start = sessionStart ?? presentation
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
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.streamFailure = self.streamFailure ?? error }
    }
}
