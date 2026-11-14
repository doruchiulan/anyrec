import Foundation

/// What the transcription pass left behind.
public enum TranscriptOutcome: Sendable {
    /// `voices` is who was told apart, for an interface that wants to offer naming
    /// the ones still lettered. `summary` is how the summary step went, when one was asked for.
    case written(files: [URL], notes: [String], voices: RecordingVoices?, summary: SummaryOutcome?)
    case nothingHeard
    /// The reason, plus what would fix it when anything would. Carried as facts rather
    /// than an `Error` so the outcome stays `Sendable` and the wording stays with
    /// whoever is showing it.
    case failed(reason: String, remedy: TranscriptionError.Remedy?)
}

/// The optional pass over files that are already closed, and the one sequence every
/// interface runs: transcribe (with any comparison engines), tell the voices apart and
/// name them, publish, review when asked, resolve competing names, summarise when asked.
/// It never throws: the recording is safe on disk before this starts, and a missing
/// model is not a reason to end the run badly.
public enum TranscriptPass {
    public static func run(
        _ plan: OutputPlan, engine: TranscriptionEngine,
        options: TranscriptionOptions? = nil, summary: SummaryRequest? = nil,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> TranscriptOutcome {
        let job = TranscriptionService.Job(
            tracks: TranscriptionService.tracks(in: plan), engine: engine,
            live: MicrophoneLive.read(plan.microphoneLive), participants: CallParticipants.read(in: plan.directory)
        )
        return await run(job, in: plan.directory, options: options, summary: summary, progress: progress)
    }

    /// A job built by the caller — `anyrec transcribe` sets the language, the whisper
    /// model and diarization from its flags, and can point at a loose audio file.
    public static func run(
        _ job: TranscriptionService.Job, in directory: URL,
        options: TranscriptionOptions? = nil, summary: SummaryRequest? = nil,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> TranscriptOutcome {
        do {
            return try await reviewed(job, directory: directory, options: options ?? .unrestricted(diarize: job.diarize),
                                      summary: summary, progress: progress) {
                try await LLMClient.complete(instructions: $0, text: $1, using: $2)
            }
        } catch {
            return .failed(reason: "\(error)", remedy: (error as? TranscriptionError)?.remedy)
        }
    }
}

extension TranscriptionOptions {
    /// What a caller with no settings of its own gets: every engine allowed, so the one
    /// asked for runs, and nothing reviewed or compared.
    static func unrestricted(diarize: Bool) -> TranscriptionOptions {
        var options = TranscriptionOptions()
        options.enabledEngines = Set(TranscriptionEngine.allCases)
        options.identifySpeakers = diarize
        return options
    }
}
