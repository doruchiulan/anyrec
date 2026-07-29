import Foundation

public enum SessionError: Error, LocalizedError, CustomStringConvertible {
    case nothingToRecord

    public var description: String {
        switch self {
        case .nothingToRecord: "Nothing was picked to record."
        }
    }

    public var errorDescription: String? { description }
}

/// How the merge into `call.mp4` went, when it was asked for at all.
public enum MergeOutcome: Sendable {
    case merged(MuxOutcome)
    case notRequested
    case ffmpegMissing
    /// The three tracks are the masters and are untouched; only the merge failed.
    case failed(String)
}

public struct RecordingOutcome: Sendable {
    public let summary: RecordingSummary
    public let merge: MergeOutcome
}

/// One recording, start to finish: the stream, the folder it writes into, the merge
/// that follows and the transcript after that. Every interface drives this same
/// object, so what a recording *does* cannot drift between them.
public final class RecordingSession {
    public let configuration: RecordingConfiguration
    public let target: ResolvedTarget
    public let plan: OutputPlan

    private let recorder: Recorder

    public var levels: LevelMonitor { recorder.levels }

    /// What is happening during `stop`, for anything drawing a status line.
    public enum Stage: Sendable {
        case finishing
        case merging
    }

    private init(
        configuration: RecordingConfiguration, target: ResolvedTarget, plan: OutputPlan,
        recorder: Recorder
    ) {
        self.configuration = configuration
        self.target = target
        self.plan = plan
        self.recorder = recorder
    }

    public static func start(
        _ configuration: RecordingConfiguration
    ) async throws -> RecordingSession {
        guard let capture = configuration.capture else { throw SessionError.nothingToRecord }

        let target = try await TargetResolver.resolve(capture.target)
        let plan = try OutputPlan.create(in: configuration.outputDirectory)
        let session = RecordingSession(
            configuration: configuration, target: target, plan: plan,
            recorder: Recorder(options: configuration.options, target: target, plan: plan)
        )
        try await session.recorder.start()
        return session
    }

    public func progress() -> RecordingProgress { recorder.progress() }

    /// Stops the stream, finalises the three tracks, and merges them when asked to.
    ///
    /// Transcription is deliberately not part of this. It runs over files that are
    /// already closed, and an interface may need to do something in between — the TUI
    /// hands the terminal back first, so the pass reports in a normal terminal rather
    /// than into a raw-mode screen.
    public func stop(progress: (Stage) -> Void = { _ in }) async throws -> RecordingOutcome {
        progress(.finishing)
        let summary = try await recorder.stop()

        guard configuration.mux else {
            return RecordingOutcome(summary: summary, merge: .notRequested)
        }
        guard Readiness.ffmpegInstalled else {
            return RecordingOutcome(summary: summary, merge: .ffmpegMissing)
        }

        progress(.merging)
        do {
            return RecordingOutcome(summary: summary, merge: .merged(try Muxer.mux(plan)))
        } catch {
            return RecordingOutcome(summary: summary, merge: .failed("\(error)"))
        }
    }

    /// Nil when no transcript was asked for.
    public func transcript(
        progress: @Sendable (String) -> Void = { _ in }
    ) async -> TranscriptOutcome? {
        guard let engine = configuration.transcribe else { return nil }
        return await TranscriptPass.run(plan, engine: engine, progress: progress)
    }
}
