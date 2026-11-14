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

    @Test("Every engine is supplied as a peer alongside a separate speaker timeline")
    func allSources() throws {
        let fixture = fixture()
        let apple = Transcript(utterances: [Utterance(start: 0, end: 6, text: "A third recognition")],
                               language: "en", engine: "apple")
        let candidates = TranscriptionCandidates(primary: fixture.primary,
            transcripts: fixture.transcripts + [apple], failures: [])
        let input = try ReviewPrompt.input(candidates, range: 0..<2)
        let object = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let sources = try #require(object["sources"] as? [[String: Any]])
        #expect(Set(sources.compactMap { $0["engine"] as? String }) == ["parakeet", "whisper", "apple"])
        #expect(sources.allSatisfy { !($0["lines"] as? [[String: Any]] ?? []).isEmpty })
        let timeline = try #require(object["timeline"] as? [[String: Any]])
        #expect(timeline.compactMap { $0["speaker"] as? String } == ["Speaker A", "Speaker B"])
        #expect(object["primary"] == nil && object["alternatives"] == nil)
    }

    @Test("a patch changes only the lines it names; unknown, duplicate or empty IDs are ignored")
    func patch() throws {
        let original = fixture().primary.transcript
        let cases: [(String, [String])] = [
            ("[]", ["I'm Alex. We'll launch on fry day.", "Yes agreed"]),
            ("[{\"id\":1,\"text\":\"Yes, agreed.\"}]", ["I'm Alex. We'll launch on fry day.", "Yes, agreed."]),
            ("[{\"id\":0,\"text\":\"x\"},{\"id\":0,\"text\":\"y\"},{\"id\":1,\"text\":\"Yes.\"}]",
             ["I'm Alex. We'll launch on fry day.", "Yes."]),
            ("[{\"id\":9,\"text\":\"y\"},{\"id\":0,\"text\":\" \"}]", ["I'm Alex. We'll launch on fry day.", "Yes agreed"]),
        ]
        for (changes, expected) in cases {
            let reply = try TranscriptReviewer.validated("{\"changes\":\(changes),\"suggestions\":[],\"speakerChanges\":[]}",
                                                         original: original, range: 0..<2)
            var lines = original.utterances.map(\.text)
            for change in reply.changes { lines[change.id] = change.text }
            #expect(lines == expected)
        }
        #expect(throws: (any Error).self) {
            try TranscriptReviewer.validated("I could not do this.", original: original, range: 0..<2)
        }
    }

    @Test("an unusable batch keeps its lines and records which; the others still apply")
    func partialFailure() async throws {
        let lines = (0..<75).map { Utterance(start: Double($0 * 2), end: Double($0 * 2 + 1), text: "line \($0)", speaker: .me) }
        let transcript = Transcript(utterances: lines, language: "en", engine: "parakeet")
        let candidates = TranscriptionCandidates(primary: .init(transcript: transcript, voices: nil), transcripts: [transcript], failures: [])
        let result = try await TranscriptReviewer.review(candidates, using: .claude, progress: { _ in }) { _, input, _ in
            let object = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
            let ids = try #require(object["timeline"] as? [[String: Any]]).compactMap { $0["id"] as? Int }
            if ids.contains(40) { return "not json" }
            if ids.contains(70) { throw TranscriptionError.engineFailed(engine: "claude", log: "rate limited") }
            return "{\"changes\":[{\"id\":\(ids[0]),\"text\":\"Line \(ids[0]).\"}],\"suggestions\":[]}"
        }
        #expect(result.transcript.utterances[0].text == "Line 0.")
        #expect(result.transcript.utterances[30].text == "line 30")
        #expect(result.transcript.utterances[60].text == "line 60")
        #expect(result.review.batchCount == 3)
        #expect(result.review.batchFailures.map(\.first) == [30, 60])
        #expect(result.review.batchFailures.map(\.last) == [59, 74])
        #expect(result.transcript.notes.contains { $0.contains("2 of 3 sections kept as transcribed") })
    }

    @Test("a review is a failure only when no batch could be used")
    func allFailed() async throws {
        await #expect(throws: (any Error).self) {
            try await TranscriptReviewer.review(fixture(), using: .claude, progress: { _ in }) { _, _, _ in "nope" }
        }
    }

    @Test("batches run a few at a time and apply in order")
    func concurrency() async throws {
        let lines = (0..<300).map { Utterance(start: Double($0 * 2), end: Double($0 * 2 + 1), text: "line \($0)", speaker: .me) }
        let transcript = Transcript(utterances: lines, language: "en", engine: "parakeet")
        let candidates = TranscriptionCandidates(primary: .init(transcript: transcript, voices: nil), transcripts: [transcript], failures: [])
        let gauge = Gauge()
        let result = try await TranscriptReviewer.review(candidates, using: .claude, progress: { _ in }) { _, input, _ in
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(20))
            await gauge.leave()
            let object = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
            let ids = try #require(object["timeline"] as? [[String: Any]]).compactMap { $0["id"] as? Int }
            let changes = ids.map { ["id": $0, "text": "Line \($0)."] as [String: Any] }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["changes": changes]), as: UTF8.self)
        }
        #expect(result.transcript.utterances.map(\.text) == (0..<300).map { "Line \($0)." })
        let peak = await gauge.peak
        #expect(peak > 1 && peak <= TranscriptReviewer.concurrency)
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
            let timeline = try #require(object["timeline"] as? [[String: Any]])
            #expect(timeline.count <= 30)
            let lines = timeline.map { ["id": $0["id"]!, "text": $0["text"]!] }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["lines": lines, "suggestions": [], "speakerChanges": []]), as: UTF8.self)
        }
        #expect(result.transcript.utterances == lines)
        #expect(result.transcript.language == "ro")
    }

    @Test("failed review leaves the original selected, says so, and keeps every source")
    func failure() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = TranscriptionOptions()
        options.review = true
        let outcome = try await TranscriptPass.publish(fixture(), in: directory, options: options, progress: { _ in }) { _, _, _ in
            throw TranscriptionError.engineFailed(engine: "test", log: "Invalid response")
        }
        guard case .written = outcome else { Issue.record("Expected usable original"); return }
        let current = try #require(RecordingTranscript.read(in: directory))
        #expect(current.transcript.engine == "parakeet")
        #expect(current.transcript.utterances == fixture().primary.transcript.utterances)
        #expect(current.transcript.notes.contains(where: { $0.contains("original kept") }))
        #expect(current.reviewFailures.contains(where: { $0.contains("original kept") }))
        #expect(current.reviewProvider == nil)
        #expect(TranscriptStore.sources(in: directory).count == 2)
    }

    @Test("review off never calls an LLM and leaves no wording layer")
    func disabled() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await TranscriptPass.publish(fixture(), in: directory, options: TranscriptionOptions(), progress: { _ in }) { _, _, _ in
            Issue.record("Review is disabled")
            throw CancellationError()
        }
        let current = try #require(RecordingTranscript.read(in: directory))
        #expect(current.wording == nil && current.reviewProvider == nil)
        #expect(TranscriptStore.sources(in: directory).map(\.role) == [.selected, .compared])
    }

    @Test("review writes a wording layer over the untouched source")
    func layered() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = TranscriptionOptions()
        options.review = true
        _ = try await TranscriptPass.publish(fixture(), in: directory, options: options, progress: { _ in }) { _, _, _ in self.reply }
        let current = try #require(RecordingTranscript.read(in: directory))
        #expect(current.transcript.utterances.map(\.text) == ["I'm Alex. We'll launch on Friday.", "Yes, agreed."])
        #expect(current.wording?.changes.map(\.line) == [0, 1])
        #expect(current.transcript.engine == "reviewed")
        #expect(Transcript.read(current.url)?.utterances == fixture().primary.transcript.utterances)
        #expect(current.wording?.compared.count == 1)
        let markdown = try String(contentsOf: current.url.deletingPathExtension().appendingPathExtension("md"), encoding: .utf8)
        #expect(markdown.contains("launch on Friday."))
    }

    @Test("a confirmed speaker correction changes one line in the speakers layer; the summary stays and is marked stale")
    func confirmedSpeaker() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = TranscriptionOptions()
        options.review = true
        _ = try await TranscriptPass.publish(fixture(), in: directory, options: options, progress: { _ in }) { _, _, _ in self.reply }
        var current = try #require(RecordingTranscript.read(in: directory))
        var summary = Summary(overview: "Old attribution", decisions: [], actions: [], provider: "test")
        summary.basis = .init(transcript: current.transcript, names: [:])
        let summaryURL = try TranscriptStore.publishSummary(summary, for: current.url, names: [:])
        let wording = current.wording
        let change = try #require(current.pendingSpeakerChanges.first)
        try TranscriptSpeakerReview.apply(change, in: directory)
        current = try #require(RecordingTranscript.read(in: directory))
        #expect(current.transcript.utterances.map(\.speaker) == [.voice("A"), .voice("A")])
        #expect(current.transcript.utterances.map(\.text) == ["I'm Alex. We'll launch on Friday.", "Yes, agreed."])
        #expect(Transcript.read(current.url)?.utterances.map(\.speaker) == [.voice("A"), .voice("B")])
        #expect(current.wording == wording)
        #expect(TranscriptStore.activeSummary(in: directory) == summaryURL)
        #expect(Summary.read(summaryURL)?.staleness(of: current.transcript, names: [:]) == .transcriptChanged)
        #expect(current.pendingSpeakerChanges.isEmpty)
        #expect(throws: (any Error).self) { try TranscriptSpeakerReview.apply(change, in: directory) }
    }

    @Test("a generation written before layers reads as it was, and moves into layers only when changed")
    func legacyGeneration() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidates = fixture()
        let name = "transcript-reviewed-\(UUID())"
        try TranscriptionService.write(candidates.primary.transcript, into: directory, named: name)
        try candidates.primary.voices?.write(to: directory.appendingPathComponent("voices-1.json"))
        let review = TranscriptReview(provider: .claude, sources: candidates.transcripts, suggestions: [], failures: [],
            speakerChanges: [SpeakerCorrection(line: 1, from: .voice("B"), to: .voice("A"), reason: "Continuation", quote: "I'm Alex", evidenceLine: 0)])
        try JSONEncoder().encode(review).write(to: directory.appendingPathComponent("review-1.json"))
        let summary = directory.appendingPathComponent("summary-reviewed-1.json")
        try Summary(overview: "Kept", decisions: [], actions: [], provider: "test").write(to: summary)
        let selection = #"{"transcript":"\#(name).json","voices":"voices-1.json","summary":"summary-reviewed-1.json","review":"review-1.json"}"#
        try Data(selection.utf8).write(to: directory.appendingPathComponent(".transcription.json"))
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()

        let current = try #require(RecordingTranscript.read(in: directory))
        #expect(!current.isLayered && current.voices?.voices.count == 2 && current.reviewProvider == .claude)
        #expect(current.pendingSpeakerChanges.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == before)

        try TranscriptSpeakerReview.apply(current.pendingSpeakerChanges[0], in: directory)
        let migrated = try #require(RecordingTranscript.read(in: directory))
        #expect(migrated.isLayered)
        #expect(migrated.transcript.utterances.map(\.speaker) == [.voice("A"), .voice("A")])
        #expect(migrated.voices?.voices.count == 2)
        #expect(TranscriptStore.activeSummary(in: directory) == summary)
        #expect(Transcript.read(directory.appendingPathComponent("\(name).json")) == candidates.primary.transcript)
    }

    private var reply: String {
        """
        {"changes":[{"id":0,"text":"I'm Alex. We'll launch on Friday."},{"id":1,"text":"Yes, agreed."}],
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

private actor Gauge {
    private var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}
