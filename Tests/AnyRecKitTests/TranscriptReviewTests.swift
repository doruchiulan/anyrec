import Foundation
import Testing
@testable import AnyRecKit

@Suite("Transcript review")
struct TranscriptReviewTests {
    @Test("review uses both engines and changes text without applying identity suggestions")
    func review() async throws {
        let candidates = fixture()
        let result = try await TranscriptReviewer.review(candidates, using: .claude, progress: { _ in }) { _, input, _ in
            #expect(input.contains("whisper") && input.contains("launch on Friday"))
            return self.reply
        }
        #expect(result.transcript.utterances.map(\.text) == ["I'm Alex. We'll launch on Friday.", "Yes, agreed."])
        #expect(result.transcript.utterances.map(\.speaker) == [.voice("A"), .voice("B")])
        #expect(result.transcript.utterances.map(\.start) == [0, 4])
        #expect(result.transcript.utterances.map(\.end) == [4, 6])
        #expect(result.review.sources.count == 2)
        #expect(result.review.sources[0].utterances[0].text.contains("fry day"))
        #expect(result.review.suggestions.map(\.name) == ["Alex"])
        #expect(result.review.speakerChanges.count == 1)
        #expect(candidates.primary.voices?.names.isEmpty == true)
    }

    @Test("missing, duplicate, unknown or empty line IDs reject the whole review")
    func invalidStructure() {
        let original = fixture().primary.transcript
        for lines in ["[]", "[{\"id\":0,\"text\":\"x\"},{\"id\":0,\"text\":\"y\"}]",
                      "[{\"id\":0,\"text\":\"x\"},{\"id\":9,\"text\":\"y\"}]",
                      "[{\"id\":0,\"text\":\" \"},{\"id\":1,\"text\":\"y\"}]"] {
            #expect(throws: (any Error).self) {
                try TranscriptReviewer.validated("{\"lines\":\(lines),\"suggestions\":[],\"speakerChanges\":[]}",
                                                 original: original, range: 0..<2)
            }
        }
    }

    @Test("speaker suggestions require a real speaker and a verbatim source quote")
    func inventedNames() async throws {
        let output = reply.replacingOccurrences(of: "I'm Alex", with: "I'm Taylor")
            .replacingOccurrences(of: "Speaker A", with: "Speaker Z")
        let result = try await TranscriptReviewer.review(fixture(), using: .claude, progress: { _ in }) { _, _, _ in output }
        #expect(result.review.suggestions.isEmpty)
        #expect(result.review.speakerChanges.isEmpty)
    }

    @Test("long transcripts are reviewed in bounded batches with stable IDs")
    func batches() async throws {
        let lines = (0..<75).map { Utterance(start: Double($0 * 2), end: Double($0 * 2 + 1), text: "Line \($0).", speaker: .me) }
        let transcript = Transcript(utterances: lines, language: "ro", engine: "whisper")
        let candidates = TranscriptionCandidates(primary: .init(transcript: transcript, voices: nil), transcripts: [transcript], failures: [])
        let result = try await TranscriptReviewer.review(candidates, using: .claude, progress: { _ in }) { _, input, _ in
            let object = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
            let primary = try #require(object["primary"] as? [[String: Any]])
            #expect(primary.count <= 30)
            let lines = primary.map { ["id": $0["id"]!, "text": $0["text"]!] }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["lines": lines, "suggestions": [], "speakerChanges": []]), as: UTF8.self)
        }
        #expect(result.transcript.utterances == lines)
        #expect(result.transcript.language == "ro")
    }

    @Test("failed review leaves an original selected and retains all source transcripts")
    func failure() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = TranscriptionOptions()
        options.review = true
        let outcome = try await TranscriptPass.publish(fixture(), in: directory, options: options, progress: { _ in }) { _, _ in
            throw TranscriptionError.engineFailed(engine: "test", log: "Invalid response")
        }
        guard case .written = outcome else { Issue.record("Expected usable original"); return }
        let transcript = Transcript.read(try #require(TranscriptStore.activeTranscript(in: directory)))
        #expect(transcript?.engine == "parakeet")
        #expect(transcript?.utterances == fixture().primary.transcript.utterances)
        #expect(transcript?.notes.contains(where: { $0.contains("original kept") }) == true)
        #expect(TranscriptReview.read(in: directory)?.failures.contains(where: { $0.contains("original kept") }) == true)
        #expect(TranscriptReview.read(in: directory)?.sources.count == 2)
    }

    @Test("review off never calls an LLM and preserves parallel sources")
    func disabled() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await TranscriptPass.publish(fixture(), in: directory, options: TranscriptionOptions(), progress: { _ in }) { _, _ in
            Issue.record("Review is disabled")
            throw CancellationError()
        }
        #expect(TranscriptReview.read(in: directory)?.provider == nil)
        #expect(TranscriptReview.read(in: directory)?.sources.count == 2)
    }

    @Test("confirmed speaker correction changes only that line, preserves originals and invalidates summary")
    func confirmedSpeaker() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await TranscriptReviewer.review(fixture(), using: .claude, progress: { _ in }) { _, _, _ in self.reply }
        let files = try TranscriptStore.publish(result.transcript, voices: fixture().primary.voices, in: directory, review: result.review)
        let summary = TranscriptStore.summaryDestination(for: files[2])
        try Summary(overview: "Old attribution", decisions: [], actions: [], provider: "test").write(to: summary)
        #expect(try TranscriptStore.selectSummary(summary, for: files[2]))
        let change = try #require(result.review.speakerChanges.first)
        let updated = try TranscriptSpeakerReview.apply(change, to: files[2])
        #expect(Transcript.read(updated[2])?.utterances.map(\.speaker) == [.voice("A"), .voice("A")])
        #expect(Transcript.read(files[2])?.utterances.map(\.speaker) == [.voice("A"), .voice("B")])
        #expect(TranscriptStore.activeSummary(in: directory) == nil)
        #expect(TranscriptReview.read(in: directory)?.speakerChanges.isEmpty == true)
        #expect(TranscriptReview.read(in: directory)?.sources.count == 2)
        #expect(throws: (any Error).self) { try TranscriptSpeakerReview.apply(change, to: files[2]) }
    }

    private var reply: String {
        """
        {"lines":[{"id":0,"text":"I'm Alex. We'll launch on Friday."},{"id":1,"text":"Yes, agreed."}],
        "suggestions":[{"letter":"A","name":"Alex","quote":"I'm Alex","line":0}],
        "speakerChanges":[{"line":1,"target":"Speaker A","reason":"Continuation of Alex's thought",
        "quote":"I'm Alex","evidenceLine":0}]}
        """
    }

    private func fixture() -> TranscriptionCandidates {
        let lines = [Utterance(start: 0, end: 4, text: "I'm Alex. We'll launch on fry day.", speaker: .voice("A")),
                     Utterance(start: 4, end: 6, text: "Yes agreed", speaker: .voice("B"))]
        let primary = Transcript(utterances: lines, language: "en", engine: "parakeet")
        let alternate = Transcript(utterances: [Utterance(start: 0, end: 6, text: "I'm Alex. We'll launch on Friday. Yes agreed")],
                                   language: "en", engine: "whisper")
        let voices = RecordingVoices(voices: [.init(letter: "A", print: [], sample: lines[0].text, start: 0, end: 4),
                                              .init(letter: "B", print: [], sample: lines[1].text, start: 4, end: 6)])
        return TranscriptionCandidates(primary: .init(transcript: primary, voices: voices), transcripts: [primary, alternate], failures: [])
    }

    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-review-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return OutputPlan(directory: directory).directory
    }
}
