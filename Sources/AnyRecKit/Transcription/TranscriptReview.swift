import Foundation

public struct SpeakerSuggestion: Codable, Equatable, Sendable, Identifiable {
    public var id: String { letter }
    public let letter: String
    public let name: String
    public let quote: String
    public let line: Int
}

/// A section of the transcript the reviewer could not be used on, kept exactly as
/// transcribed. `first` and `last` are line indexes, inclusive.
public struct ReviewBatchFailure: Codable, Equatable, Sendable {
    public let first: Int
    public let last: Int
    public let reason: String
}

public struct TranscriptReview: Codable, Sendable {
    public let provider: SummaryProvider?
    public let sources: [Transcript]
    public let suggestions: [SpeakerSuggestion]
    public let failures: [String]
    public var speakerChanges: [SpeakerCorrection] = []
    /// Sections kept as transcribed because their reply could not be used. Empty for a
    /// review written before sections could fail on their own.
    public var batchFailures: [ReviewBatchFailure] = []
    public var batchCount = 0

    public init(provider: SummaryProvider?, sources: [Transcript], suggestions: [SpeakerSuggestion],
                failures: [String], speakerChanges: [SpeakerCorrection] = [],
                batchFailures: [ReviewBatchFailure] = [], batchCount: Int = 0) {
        self.provider = provider
        self.sources = sources
        self.suggestions = suggestions
        self.failures = failures
        self.speakerChanges = speakerChanges
        self.batchFailures = batchFailures
        self.batchCount = batchCount
    }

    private enum CodingKeys: String, CodingKey {
        case provider, sources, suggestions, failures, speakerChanges, batchFailures, batchCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decodeIfPresent(SummaryProvider.self, forKey: .provider)
        sources = try values.decodeIfPresent([Transcript].self, forKey: .sources) ?? []
        suggestions = try values.decodeIfPresent([SpeakerSuggestion].self, forKey: .suggestions) ?? []
        failures = try values.decodeIfPresent([String].self, forKey: .failures) ?? []
        speakerChanges = try values.decodeIfPresent([SpeakerCorrection].self, forKey: .speakerChanges) ?? []
        batchFailures = try values.decodeIfPresent([ReviewBatchFailure].self, forKey: .batchFailures) ?? []
        batchCount = try values.decodeIfPresent(Int.self, forKey: .batchCount) ?? 0
    }

    public static func read(in directory: URL) -> TranscriptReview? {
        guard let name = TranscriptStore.selection(in: directory)?.review,
              let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// The wording pass. The model returns a patch — only the lines it changed — so a reply
/// that leaves something out has left it unchanged rather than broken the transcript.
/// Each batch stands alone: one unusable reply keeps that section as transcribed and the
/// rest of the review still counts.
public enum TranscriptReviewer {
    struct Reply: Decodable, Sendable {
        struct Line: Decodable, Sendable { let id: Int; let text: String }
        let changes: [Line]
        let suggestions: [SpeakerSuggestion]
        var speakerChanges: [ProposedSpeakerChange] = []

        private enum CodingKeys: String, CodingKey { case changes, lines, suggestions, speakerChanges }

        init(changes: [Line], suggestions: [SpeakerSuggestion], speakerChanges: [ProposedSpeakerChange]) {
            self.changes = changes
            self.suggestions = suggestions
            self.speakerChanges = speakerChanges
        }

        /// `lines` is the old full-restatement shape; read the same way, as changes.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard let changes = try values.decodeIfPresent([Line].self, forKey: .changes)
                ?? values.decodeIfPresent([Line].self, forKey: .lines) else {
                throw DecodingError.keyNotFound(CodingKeys.changes, .init(codingPath: [], debugDescription: "No changes"))
            }
            self.changes = changes
            suggestions = try values.decodeIfPresent([SpeakerSuggestion].self, forKey: .suggestions) ?? []
            speakerChanges = (try? values.decodeIfPresent([ProposedSpeakerChange].self, forKey: .speakerChanges)) ?? []
        }
    }

    public struct Reviewed: Sendable {
        public let transcript: Transcript
        public let review: TranscriptReview
    }

    typealias Completion = @Sendable (String, String, SummaryProvider) async throws -> String

    /// How many batches are in flight at once. Each is a separate `claude -p` (or API
    /// call); more than a few only queues behind the provider's own limits.
    static let concurrency = 3

    public static func review(
        _ candidates: TranscriptionCandidates, using provider: SummaryProvider, sheet: CallSheet? = nil,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Reviewed {
        try await review(candidates, using: provider, sheet: sheet, progress: progress) {
            try await LLMClient.complete(instructions: $0, text: $1, using: $2)
        }
    }

    private struct BatchResult: Sendable {
        let index: Int
        let range: Range<Int>
        let reply: Reply?
        let failure: String?
    }

    static func review(
        _ candidates: TranscriptionCandidates, using provider: SummaryProvider, sheet: CallSheet? = nil,
        progress: @escaping @Sendable (String) -> Void, complete: @escaping Completion
    ) async throws -> Reviewed {
        let original = candidates.primary.transcript
        let batches = ReviewPrompt.batches(for: original)
        progress("Reviewing transcript with \(provider.name) — 0 of \(batches.count)…")
        let results = try await withThrowingTaskGroup(of: BatchResult.self) { group in
            var next = 0
            var finished: [BatchResult] = []
            func start() {
                let index = next, range = batches[index]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        let input = try ReviewPrompt.input(candidates, range: range, sheet: sheet)
                        let output = try await complete(ReviewPrompt.instructions, input, provider)
                        try Task.checkCancellation()
                        return BatchResult(index: index, range: range,
                                           reply: try validated(output, original: original, range: range), failure: nil)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return BatchResult(index: index, range: range, reply: nil, failure: Self.reason(error))
                    }
                }
            }
            while next < min(concurrency, batches.count) { start() }
            while let result = try await group.next() {
                finished.append(result)
                progress("Reviewing transcript with \(provider.name) — \(finished.count) of \(batches.count)…")
                if next < batches.count { start() }
            }
            return finished.sorted { $0.index < $1.index }
        }
        try Task.checkCancellation()

        var lines = original.utterances
        var suggestions: [SpeakerSuggestion] = []
        var changes: [SpeakerCorrection] = []
        var failed: [ReviewBatchFailure] = []
        for result in results {
            guard let reply = result.reply else {
                failed.append(ReviewBatchFailure(first: result.range.lowerBound, last: result.range.upperBound - 1,
                                                 reason: result.failure ?? "No usable reply."))
                continue
            }
            for line in reply.changes { lines[line.id].text = line.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            suggestions += reply.suggestions
            changes += reply.speakerChanges.compactMap { $0.validated(in: original, range: result.range) }
        }
        guard failed.count < batches.count else {
            let reason = failed.first?.reason ?? "No section could be reviewed."
            throw TranscriptionError.engineFailed(engine: "review", log: "No section of the review could be used. \(reason)")
        }
        let note = failed.isEmpty
            ? "Reviewed with \(provider.name); original transcripts retained."
            : "Reviewed with \(provider.name); \(failed.count) of \(batches.count) sections kept as transcribed. Original transcripts retained."
        let transcript = Transcript(utterances: lines, language: original.language, engine: "reviewed",
                                    notes: original.notes + [note])
        return Reviewed(transcript: transcript, review: TranscriptReview(provider: provider,
            sources: [original] + candidates.transcripts.filter { $0.engine != original.engine },
            suggestions: suggestions, failures: candidates.failures + failed.map(Self.describe),
            speakerChanges: uniqueChanges(changes), batchFailures: failed, batchCount: batches.count))
    }

    /// Name suggestions worth showing: one name per letter, only for voices still unnamed
    /// once identities have been resolved.
    static func accepted(_ suggestions: [SpeakerSuggestion], voices: RecordingVoices?) -> [SpeakerSuggestion] {
        let unnamed = Set(voices?.unnamed.map(\.letter) ?? [])
        let unambiguous = suggestions.filter { suggestion in
            unnamed.contains(suggestion.letter)
                && Set(suggestions.filter { $0.letter == suggestion.letter }.map(\.name)).count == 1
        }
        var seen = Set<String>()
        return unambiguous.filter { seen.insert($0.letter).inserted }
    }

    static func describe(_ failure: ReviewBatchFailure) -> String {
        "Lines \(failure.first + 1)–\(failure.last + 1) kept as transcribed: \(failure.reason)"
    }

    private static func reason(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        return String(text.prefix(300))
    }

    private static func uniqueChanges(_ changes: [SpeakerCorrection]) -> [SpeakerCorrection] {
        var seen = Set<Int>()
        return changes.filter { change in
            Set(changes.filter { $0.line == change.line }.map(\.to)).count == 1
                && seen.insert(change.line).inserted
        }
    }

    /// The reply's usable part. Throws only when there is no reply to read at all; an id
    /// outside the batch, an empty line or a line grown past its limit is dropped and the
    /// rest kept, and a line the reply leaves out is unchanged.
    static func validated(_ output: String, original: Transcript, range: Range<Int>) throws -> Reply {
        guard let first = output.firstIndex(of: "{"), let last = output.lastIndex(of: "}"), first < last,
              let data = String(output[first...last]).data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw TranscriptionError.engineFailed(engine: "review", log: "The reply was not a usable review.")
        }
        var seen = Set<Int>()
        let duplicated = Set(reply.changes.map(\.id).filter { !seen.insert($0).inserted })
        let changes = reply.changes.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return range.contains(line.id) && !duplicated.contains(line.id) && !text.isEmpty
                && text.count <= max(1_000, original.utterances[line.id].text.count * 4)
                && text != original.utterances[line.id].text
        }
        let valid = reply.suggestions.filter { suggestion in
            guard range.contains(suggestion.line), !suggestion.name.trimmingCharacters(in: .whitespaces).isEmpty,
                  suggestion.name.count <= 100, suggestion.quote.count >= 3 else { return false }
            let evidence = original.utterances[suggestion.line]
            return evidence.speaker == .voice(suggestion.letter) && evidence.text.contains(suggestion.quote)
        }
        return Reply(changes: changes, suggestions: valid, speakerChanges: reply.speakerChanges)
    }
}
