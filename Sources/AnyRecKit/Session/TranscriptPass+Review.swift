import Foundation

extension TranscriptPass {
    static func reviewed(
        _ job: TranscriptionService.Job, directory: URL, options: TranscriptionOptions, summary: SummaryRequest?,
        progress: @escaping @Sendable (String) -> Void, complete: @escaping TranscriptReviewer.Completion
    ) async throws -> TranscriptOutcome {
        let readiness = await Readiness.probe()
        let available = Set(TranscriptionEngine.allCases.filter { readiness.of($0).isReady })
        var engines = options.engines(preferred: job.engine, available: available)
        /// The engine asked for runs even when it is not ready, so it can say why — with
        /// the way out (a model to fetch, a key to paste) attached.
        if engines.isEmpty { engines = [job.engine] }
        var job = job
        job.diarize = options.identifySpeakers
        job.enabledEngines = options.enabledEngines
        let candidates = try await TranscriptionService.candidates(
            job, engines: engines, identifySpeakers: options.identifySpeakers, progress: progress)
        return try await publish(candidates, in: directory, options: options, summary: summary,
                                 progress: progress, complete: complete)
    }

    static func publish(
        _ candidates: TranscriptionCandidates, in directory: URL, options: TranscriptionOptions,
        summary: SummaryRequest? = nil,
        library: () -> VoiceLibrary = { VoiceLibrary.load() },
        progress: @escaping @Sendable (String) -> Void,
        complete: @escaping TranscriptReviewer.Completion
    ) async throws -> TranscriptOutcome {
        let primary = candidates.primary
        guard !primary.transcript.isEmpty else {
            try TranscriptStore.recordNoSpeech(in: directory)
            return .nothingHeard
        }
        let others = candidates.transcripts.filter { $0.engine != primary.transcript.engine }
        /// The person recording is called by the library owner's name from the start, so the
        /// transcript, its Markdown and the summary never say "Me" once the owner is known.
        var voices = RecordingVoices.withMe(primary.voices, named: library().owner?.shownName)
        var files = try TranscriptStore.publish(primary.transcript, voices: voices, in: directory, compared: others)
        var notes = primary.transcript.notes

        if options.review, let selection = TranscriptStore.selection(in: directory) {
            let provider = options.reviewProvider
            var problems: [String] = []
            var reviewed: TranscriptReviewer.Reviewed?
            progress("Reading the call with \(provider.name)…")
            let sheet = await CallSheet.facts(
                in: directory, transcript: primary.transcript, voices: voices, vocabulary: options.vocabulary,
                library: library()
            ).withTopic(primary.transcript, using: provider, complete: complete)
            try Task.checkCancellation()
            do {
                reviewed = try await TranscriptReviewer.review(
                    candidates, using: provider, sheet: sheet, progress: progress, complete: complete)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                problems.append("Transcript review failed; original kept. \(error)")
            }
            try Task.checkCancellation()

            /// Names are settled apart from wording: a wording reply that could not be used
            /// is no reason to leave two candidate names unresolved.
            if voices?.voices.contains(where: { $0.identityEvidence?.conflict == true }) == true {
                progress("Resolving speaker identities with \(provider.name)…")
                do {
                    voices = try await SpeakerIdentityReview.resolve(
                        voices, transcript: reviewed?.transcript ?? primary.transcript,
                        suggestions: reviewed?.review.suggestions ?? [], using: provider, complete: complete)
                    /// The review picks between candidate names as written (a saved name such
                    /// as "Andi"); the transcript shows that person the way any other is shown.
                    if var resolved = voices {
                        ParticipantAttribution.showDisplayNames(&resolved, library: library())
                        voices = resolved
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    problems.append("Speaker names could not be resolved; both candidates kept. \(error)")
                }
            }
            try Task.checkCancellation()

            /// The lines no voice claimed, read from the conversation around each: words cut off
            /// a neighbour's sentence, a reply to a question put to someone by name.
            let proposed = reviewed?.review.speakerChanges ?? []
            var unclaimed = UnclaimedLineReview.Placement()
            var unclaimedAsked: [Int]?
            let lines = reviewed?.transcript.utterances ?? primary.transcript.utterances
            let asked = lines.indices.filter { lines[$0].speaker == .others && !proposed.map(\.line).contains($0) }
            if !asked.isEmpty {
                do {
                    unclaimed = try await UnclaimedLineReview.placement(
                        for: asked, in: lines, voices: voices, participants: CallParticipants.read(in: directory),
                        using: provider, progress: progress, complete: complete)
                    unclaimedAsked = asked
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    problems.append("The lines nobody claimed could not be placed. \(error)")
                }
            }
            try Task.checkCancellation()

            let original = primary.transcript.utterances
            let changes = reviewed.map { result in
                zip(original.indices, result.transcript.utterances).compactMap { index, line in
                    line.text == original[index].text ? nil : WordingLayer.Change(line: index, text: line.text)
                }
            } ?? []
            let reviewNotes = Array((reviewed?.transcript.notes ?? primary.transcript.notes).dropFirst(primary.transcript.notes.count))
            let wording = WordingLayer(
                source: selection.transcript, lineCount: original.count, provider: reviewed == nil ? nil : provider,
                changes: changes, compared: selection.compared ?? [],
                suggestions: TranscriptReviewer.accepted(reviewed?.review.suggestions ?? [], voices: voices),
                speakerChanges: proposed + unclaimed.all,
                failures: candidates.failures + (reviewed?.review.batchFailures.map(TranscriptReviewer.describe) ?? []) + problems,
                batchFailures: reviewed?.review.batchFailures ?? [], batchCount: reviewed?.review.batchCount ?? 0,
                notes: reviewNotes + problems, callSheet: sheet, unclaimedAsked: unclaimedAsked)
            let worded = try TranscriptStore.publishWording(wording, voices: voices, in: directory)
            if !worded.isEmpty { files = worded }
            notes += wording.notes
            problems.forEach(progress)
        }

        var summarised: SummaryOutcome?
        if let summary {
            progress("Writing the summary with \(summary.provider.name)…")
            do {
                summarised = .written(try await SummaryPass.write(in: directory, request: summary, complete: complete))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                summarised = .failed("\(error)")
            }
        }
        return .written(files: files, notes: notes, voices: voices, summary: summarised)
    }
}
