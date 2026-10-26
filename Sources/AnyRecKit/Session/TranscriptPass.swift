import Foundation

/// What the transcription pass left behind.
public enum TranscriptOutcome: Sendable {
    /// `voices` is who was told apart, for an interface that wants to offer naming
    /// the ones still lettered.
    case written(files: [URL], notes: [String], voices: RecordingVoices?)
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
        options: TranscriptionOptions? = nil,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> TranscriptOutcome {
        do {
            let job = TranscriptionService.Job(
                tracks: TranscriptionService.tracks(in: plan), engine: engine,
                live: MicrophoneLive.read(plan.microphoneLive)
            )
            if let options { return try await reviewed(job, plan: plan, options: options, progress: progress) }
            let transcribed = try await TranscriptionService.run(job, progress: progress)
            let transcript = transcribed.transcript
            guard !transcript.isEmpty else {
                try TranscriptStore.recordNoSpeech(in: plan.directory)
                return .nothingHeard
            }

            let files = try TranscriptStore.publish(transcript, voices: transcribed.voices, in: plan.directory)
            return .written(files: files, notes: transcript.notes, voices: transcribed.voices)
        } catch {
            return .failed(
                reason: "\(error)", remedy: (error as? TranscriptionError)?.remedy
            )
        }
    }
}
