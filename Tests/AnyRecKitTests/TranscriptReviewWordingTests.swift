import Foundation
import Testing
@testable import AnyRecKit

@Suite("Transcript review wording")
struct TranscriptReviewWordingTests {
    @Test("live review preserves spoken wording while correcting recognition errors",
          .enabled(if: ProcessInfo.processInfo.environment["ANYREC_LIVE_REVIEW_TEST"] == "1"))
    func spokenWording() async throws {
        let spoken = [
            "useri care nu-s logged in",
            "we're gonna ship it",
            "deci deci facem deploy după meeting",
            "mă uit pe dashboard și dau un refresh",
            "we launch on fry day",
        ]
        let alternative = [
            "user care nu se loghează",
            "we are going to release it",
            "Vom publica după ședință.",
            "Verific panoul de control și actualizez pagina.",
            "We launch on Friday.",
        ]
        let primary = transcript(spoken, engine: "parakeet")
        let candidates = TranscriptionCandidates(
            primary: .init(transcript: primary, voices: nil),
            transcripts: [primary, transcript(alternative, engine: "whisper")], failures: [])
        let reviewed = try await TranscriptReviewer.review(candidates, using: .claude)
        let lines = reviewed.transcript.utterances
        #expect(lines.count == spoken.count)
        for (line, expected) in zip(lines, Array(spoken.prefix(4)) + ["we launch on Friday"]) {
            #expect(words(line.text) == words(expected))
        }
        #expect(lines.map(\.start) == primary.utterances.map(\.start))
        #expect(lines.map(\.end) == primary.utterances.map(\.end))
        #expect(lines.map(\.speaker) == primary.utterances.map(\.speaker))
        #expect(reviewed.review.sources.first?.utterances == primary.utterances)
    }

    private func transcript(_ texts: [String], engine: String) -> Transcript {
        Transcript(utterances: texts.enumerated().map { index, text in
            Utterance(start: Double(index * 5), end: Double(index * 5 + 4), text: text, speaker: .me)
        }, language: "ro", engine: engine)
    }

    private func words(_ text: String) -> [String] {
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-"))
        return text.lowercased().components(separatedBy: word.inverted).filter { !$0.isEmpty }
    }
}
