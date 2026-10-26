import Foundation

extension TranscriptPass {
    static func reviewed(
        _ job: TranscriptionService.Job, plan: OutputPlan, options: TranscriptionOptions,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> TranscriptOutcome {
        let readiness = await Readiness.probe()
        let available = Set(TranscriptionEngine.allCases.filter { readiness.of($0).isReady })
        var engines = options.engines(preferred: job.engine, available: available)
        if !options.parallel, job.engine == .auto, !engines.isEmpty { engines = [.auto] }
        var job = job
        job.diarize = options.identifySpeakers
        job.enabledEngines = options.parallel ? Set(engines) : options.enabledEngines
        let candidates = try await TranscriptionService.candidates(
            job, engines: engines, identifySpeakers: options.identifySpeakers, progress: progress)
        return try await publish(candidates, in: plan.directory, options: options, progress: progress) {
            try await TranscriptReviewer.review($0, using: $1, progress: progress)
        }
    }

    static func publish(
        _ candidates: TranscriptionCandidates, in directory: URL, options: TranscriptionOptions,
        progress: @escaping @Sendable (String) -> Void,
        review: (TranscriptionCandidates, SummaryProvider) async throws -> TranscriptReviewer.Reviewed
    ) async throws -> TranscriptOutcome {
        let primary = candidates.primary
        guard !primary.transcript.isEmpty else {
            try TranscriptStore.recordNoSpeech(in: directory)
            return .nothingHeard
        }
        let source = TranscriptReview(provider: nil,
            sources: [primary.transcript] + candidates.transcripts.filter { $0.engine != primary.transcript.engine },
            suggestions: [], failures: candidates.failures)
        var files = try TranscriptStore.publish(primary.transcript, voices: primary.voices, in: directory, review: source)
        var notes = primary.transcript.notes
        if options.review {
            do {
                let reviewed = try await review(candidates, options.reviewProvider)
                try Task.checkCancellation()
                files = try TranscriptStore.publish(reviewed.transcript, voices: primary.voices,
                                                    in: directory, review: reviewed.review)
                notes = reviewed.transcript.notes
            } catch {
                let message = "Transcript review failed; original kept. \(error)"
                notes.append(message)
                let original = primary.transcript
                let kept = Transcript(utterances: original.utterances, language: original.language,
                                      engine: original.engine, notes: notes)
                let failed = TranscriptReview(provider: nil, sources: source.sources, suggestions: [],
                                              failures: source.failures + [message])
                files = try TranscriptStore.publish(kept, voices: primary.voices, in: directory, review: failed)
                progress(message)
            }
        }
        return .written(files: files, notes: notes, voices: primary.voices)
    }
}
