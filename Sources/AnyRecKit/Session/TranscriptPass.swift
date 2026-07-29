import Foundation

/// What the transcription pass left behind.
public enum TranscriptOutcome: Sendable {
    case written(files: [URL], notes: [String])
    case nothingHeard
    /// The reason, plus what would fix it when anything would. Carried as facts rather
    /// than an `Error` so the outcome stays `Sendable` and the wording stays with
    /// whoever is showing it.
    case failed(reason: String, remedy: TranscriptionError.Remedy?)
}

/// The optional pass over files that are already closed. It never throws: the
/// recording is safe on disk before this starts, and a missing model is not a reason
/// to end the run badly.
public enum TranscriptPass {
    public static func run(
        _ plan: OutputPlan, engine: TranscriptionEngine,
        progress: @Sendable (String) -> Void = { _ in }
    ) async -> TranscriptOutcome {
        do {
            let job = TranscriptionService.Job(
                tracks: TranscriptionService.tracks(in: plan), engine: engine
            )
            let transcript = try await TranscriptionService.run(job, progress: progress)
            guard !transcript.isEmpty else { return .nothingHeard }

            let files = try TranscriptionService.write(
                transcript, into: plan.directory, named: "transcript-\(transcript.engine)"
            )
            return .written(files: files, notes: transcript.notes)
        } catch {
            return .failed(
                reason: "\(error)", remedy: (error as? TranscriptionError)?.remedy
            )
        }
    }
}
