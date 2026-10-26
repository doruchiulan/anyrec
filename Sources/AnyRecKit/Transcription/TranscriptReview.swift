import Foundation

public struct SpeakerSuggestion: Codable, Equatable, Sendable, Identifiable {
    public var id: String { letter }
    public let letter: String
    public let name: String
    public let quote: String
    public let line: Int
}

public struct TranscriptReview: Codable, Sendable {
    public let provider: SummaryProvider?
    public let sources: [Transcript]
    public let suggestions: [SpeakerSuggestion]
    public let failures: [String]
    public var speakerChanges: [SpeakerCorrection] = []

    public static func read(in directory: URL) -> TranscriptReview? {
        guard let name = TranscriptStore.selection(in: directory)?.review,
              let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

public enum TranscriptReviewer {
    struct Reply: Decodable {
        struct Line: Decodable { let id: Int; let text: String }
        let lines: [Line]
        let suggestions: [SpeakerSuggestion]
        var speakerChanges: [ProposedSpeakerChange] = []
    }

    public struct Reviewed: Sendable {
        public let transcript: Transcript
        public let review: TranscriptReview
    }

    typealias Completion = @Sendable (String, String, SummaryProvider) async throws -> String

    public static func review(
        _ candidates: TranscriptionCandidates, using provider: SummaryProvider,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Reviewed {
        try await review(candidates, using: provider, progress: progress) {
            try await LLMClient.complete(instructions: $0, text: $1, using: $2)
        }
    }

    static func review(
        _ candidates: TranscriptionCandidates, using provider: SummaryProvider,
        progress: @escaping @Sendable (String) -> Void, complete: Completion
    ) async throws -> Reviewed {
        let original = candidates.primary.transcript
        var lines = original.utterances
        var suggestions: [SpeakerSuggestion] = []
        var changes: [SpeakerCorrection] = []
        let batches = ReviewPrompt.batches(for: original)
        for (index, range) in batches.enumerated() {
            try Task.checkCancellation()
            progress("Reviewing transcript with \(provider.name) — \(index + 1) of \(batches.count)…")
            let input = try ReviewPrompt.input(candidates, range: range)
            let output = try await complete(ReviewPrompt.instructions, input, provider)
            let reply = try validated(output, original: original, range: range)
            for line in reply.lines { lines[line.id].text = line.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            suggestions += reply.suggestions
            changes += reply.speakerChanges.compactMap { $0.validated(in: original, range: range) }
        }
        let unnamed = Set(candidates.primary.voices?.unnamed.map(\.letter) ?? [])
        let unambiguous = suggestions.filter { suggestion in
            unnamed.contains(suggestion.letter)
                && Set(suggestions.filter { $0.letter == suggestion.letter }.map(\.name)).count == 1
        }
        var seen = Set<String>()
        let accepted = unambiguous.filter { seen.insert($0.letter).inserted }
        let transcript = Transcript(utterances: lines, language: original.language, engine: "reviewed",
                                    notes: original.notes + ["Reviewed with \(provider.name); original transcripts retained."])
        return Reviewed(transcript: transcript, review: TranscriptReview(provider: provider,
            sources: [original] + candidates.transcripts.filter { $0.engine != original.engine },
            suggestions: accepted, failures: candidates.failures, speakerChanges: uniqueChanges(changes)))
    }

    private static func uniqueChanges(_ changes: [SpeakerCorrection]) -> [SpeakerCorrection] {
        var seen = Set<Int>()
        return changes.filter { change in
            Set(changes.filter { $0.line == change.line }.map(\.to)).count == 1
                && seen.insert(change.line).inserted
        }
    }

    static func validated(_ output: String, original: Transcript, range: Range<Int>) throws -> Reply {
        guard let first = output.firstIndex(of: "{"), let last = output.lastIndex(of: "}"), first < last,
              let data = String(output[first...last]).data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data),
              reply.lines.count == range.count, Set(reply.lines.map(\.id)) == Set(range),
              reply.lines.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.text.count <= max(1_000, original.utterances[$0.id].text.count * 4) }) else {
            throw TranscriptionError.engineFailed(engine: "review", log: "The review changed the transcript structure. The original was kept.")
        }
        let valid = reply.suggestions.filter { suggestion in
            guard range.contains(suggestion.line), !suggestion.name.trimmingCharacters(in: .whitespaces).isEmpty,
                  suggestion.name.count <= 100, suggestion.quote.count >= 3 else { return false }
            let evidence = original.utterances[suggestion.line]
            return evidence.speaker == .voice(suggestion.letter) && evidence.text.contains(suggestion.quote)
        }
        return Reply(lines: reply.lines, suggestions: valid, speakerChanges: reply.speakerChanges)
    }
}
