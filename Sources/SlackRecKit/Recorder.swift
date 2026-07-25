import AVFoundation
import Foundation
import ScreenCaptureKit

public enum RecorderError: Error, CustomStringConvertible {
    case unsupportedOutputType
    case streamStopped(Error)

    public var description: String {
        switch self {
        case .unsupportedOutputType: "ScreenCaptureKit delivered an unknown output type."
        case .streamStopped(let error): "Capture stopped early: \(error.localizedDescription)"
        }
    }
}

public struct RecordingSummary: Sendable {
    public let plan: OutputPlan
    public let screenFrames: Int
    public let systemAudioSamples: Int
    public let microphoneSamples: Int
    public let droppedSamples: Int
    public let systemAudioPeak: Float
    public let microphonePeak: Float

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

/// Drives one SCStream and fans its three output types into three files.
///
/// Every stream output shares a single serial queue, so the writer table and the
/// session clock need no further locking.
public final class Recorder: NSObject {
    private let options: CaptureOptions
    private let target: ResolvedTarget
    private let plan: OutputPlan
    private let queue = DispatchQueue(label: "ro.qlan.slack-rec.capture")

    public let levels = LevelMonitor()

    private var stream: SCStream?
    private var writers: [SCStreamOutputType: TrackWriter] = [:]
    private var sessionStart: CMTime?
    private var failure: Error?

    public init(options: CaptureOptions, target: ResolvedTarget, plan: OutputPlan) {
        self.options = options
        self.target = target
        self.plan = plan
    }

    public func start() async throws {
        let stream = SCStream(
            filter: target.filter, configuration: makeConfiguration(), delegate: self
        )
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
        let (tracks, error) = queue.sync { (writers, failure) }
        for track in tracks.values { await track.finish() }

        if let error { throw RecorderError.streamStopped(error) }
        return RecordingSummary(
            plan: plan,
            screenFrames: tracks[.screen]?.samplesWritten ?? 0,
            systemAudioSamples: tracks[.audio]?.samplesWritten ?? 0,
            microphoneSamples: tracks[.microphone]?.samplesWritten ?? 0,
            droppedSamples: tracks.values.reduce(0) { $0 + $1.samplesDropped },
            systemAudioPeak: levels.sessionPeak(for: .systemAudio),
            microphonePeak: levels.sessionPeak(for: .microphone)
        )
    }

    public func progress() -> RecordingProgress {
        queue.sync {
            RecordingProgress(
                screenFrames: writers[.screen]?.samplesWritten ?? 0,
                droppedSamples: writers.values.reduce(0) { $0 + $1.samplesDropped }
            )
        }
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = target.width
        config.height = target.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.queueDepth = 6
        config.showsCursor = options.showsCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = options.captureSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = options.captureMicrophone
        config.microphoneCaptureDeviceID = options.microphoneDeviceID
        return config
    }

    private func writer(for type: SCStreamOutputType, buffer: CMSampleBuffer) throws -> TrackWriter {
        if let existing = writers[type] { return existing }

        let format = CMSampleBufferGetFormatDescription(buffer)
        let created: TrackWriter = switch type {
        case .screen:
            try TrackWriter(
                url: plan.screen,
                kind: .video(
                    codec: options.codec.avCodecType,
                    width: target.width,
                    height: target.height
                ),
                formatHint: nil
            )
        case .audio:
            try TrackWriter(url: plan.systemAudio, kind: .audio, formatHint: format)
        case .microphone:
            try TrackWriter(url: plan.microphone, kind: .audio, formatHint: format)
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
        if type == .screen, !isCompleteFrame(sampleBuffer) { return }

        if let track = AudioTrack(type), let level = AudioLevelMeter.measure(sampleBuffer) {
            levels.record(level, for: track)
        }

        do {
            let track = try writer(for: type, buffer: sampleBuffer)
            let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let start = sessionStart ?? presentation
            sessionStart = start
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
        queue.async { self.failure = self.failure ?? error }
    }
}
