import Foundation
import Testing
@testable import AnyRecKit

@Suite("Automatic speaker identity review")
struct SpeakerIdentityReviewTests {
    @Test("Review resolves a conflict, publishes the name and preserves original voices and turns")
    func publication() async throws {
        let candidates = fixture()
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = TranscriptionOptions()
        options.review = true
        let outcome = try await TranscriptPass.publish(candidates, in: directory, options: options, progress: { _ in }) { input, provider in
            try await TranscriptReviewer.review(input, using: provider, progress: { _ in }) { _, text, _ in
                if text.contains("\"conflicts\"") {
                    #expect(text.contains("Costin") && text.contains("Alex") && text.contains("I'm Costin"))
                    #expect(!text.contains("\"print\""))
                    return self.decision("Costin")
                }
                return self.wording
            }
        }
        guard case .written(let files, _, let voices) = outcome else { Issue.record("Expected transcript"); return }
        #expect(voices?.names == ["A": "Costin"])
        #expect(voices?.voices[0].print == candidates.primary.voices?.voices[0].print)
        #expect(RecordingVoices.read(in: directory) == voices)
        #expect(Transcript.read(files[2])?.utterances == candidates.primary.transcript.utterances)
        #expect(try String(contentsOf: files[0], encoding: .utf8).contains("Costin"))
        let evidence = try #require(voices?.voices[0].identityEvidence)
        #expect(!evidence.conflict && evidence.callNames == ["Costin"] && evidence.voiceprintName == "Alex")
        #expect(evidence.resolution?.name == "Costin" && evidence.resolution?.provider == options.reviewProvider)
        #expect(evidence.resolution?.reason == "The speaker introduces himself as Costin.")
        #expect(TranscriptReview.read(in: directory)?.suggestions.isEmpty == true)
        let stored = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let generations = stored.filter { $0.lastPathComponent.hasPrefix("voices-") }.compactMap { RecordingVoices.read($0) }
        #expect(generations.count == 2)
        #expect(generations.contains(candidates.primary.voices!))
    }

    @Test("The reviewer can keep the saved voice name instead of the call indicator")
    func keepsVoiceprint() throws {
        let voices = try #require(fixture().primary.voices)
        let result = try SpeakerIdentityReview.apply(decision("Alex"), to: voices, provider: .claude)
        #expect(result.names == ["A": "Alex"])
        #expect(result.voices[0].identityEvidence?.conflict == false)
    }

    @Test("Unknown names, unknown letters, duplicate and missing decisions reject the response")
    func invalid() throws {
        let voices = try #require(fixture().primary.voices)
        let valid = decision("Costin")
        let object = #"{"letter":"A","name":"Costin","reason":"Evidence"}"#
        for output in [decision("Invented"), valid.replacingOccurrences(of: "\"A\"", with: "\"Z\""),
                       "{\"identities\":[]}", "{\"identities\":[\(object),\(object)]}", "not JSON"] {
            #expect(throws: (any Error).self) { try SpeakerIdentityReview.apply(output, to: voices, provider: .claude) }
        }
    }

    @Test("Uncertain or duplicate names leave voices unresolved")
    func ambiguity() throws {
        let voices = try #require(fixture().primary.voices)
        let abstained = #"{"identities":[{"letter":"A","name":null,"reason":"Cannot distinguish the candidates."}]}"#
        #expect(try SpeakerIdentityReview.apply(abstained, to: voices, provider: .claude) == voices)
        var occupied = voices
        occupied.voices.append(.init(letter: "B", print: [], sample: "Hello", start: 2, end: 3, name: "COSTIN"))
        #expect(try SpeakerIdentityReview.apply(decision("Costin"), to: occupied, provider: .claude) == occupied)
        var twoConflicts = voices
        var other = RecordingVoices.Voice(letter: "B", print: [], sample: "Hi", start: 2, end: 3)
        other.identityEvidence = voices.voices[0].identityEvidence
        twoConflicts.voices.append(other)
        let duplicate = #"{"identities":[{"letter":"A","name":"Costin","reason":"Clue"},{"letter":"B","name":"Costin","reason":"Clue"}]}"#
        #expect(try SpeakerIdentityReview.apply(duplicate, to: twoConflicts, provider: .claude) == twoConflicts)
    }

    @Test("Review off leaves conflicts untouched without calling the LLM")
    func disabled() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await TranscriptPass.publish(fixture(), in: directory, options: TranscriptionOptions(), progress: { _ in }) { _, _ in
            Issue.record("Review must remain opt-in")
            throw CancellationError()
        }
        #expect(RecordingVoices.read(in: directory) == fixture().primary.voices)
    }

    @Test("An invalid identity response keeps the original generation usable")
    func failedResolution() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = TranscriptionOptions()
        options.review = true
        _ = try await TranscriptPass.publish(fixture(), in: directory, options: options, progress: { _ in }) { candidates, provider in
            try await TranscriptReviewer.review(candidates, using: provider, progress: { _ in }) { _, input, _ in
                input.contains("\"conflicts\"") ? self.decision("Invented") : self.wording
            }
        }
        #expect(RecordingVoices.read(in: directory) == fixture().primary.voices)
        #expect(TranscriptReview.read(in: directory)?.failures.isEmpty == false)
        #expect(Transcript.read(try #require(TranscriptStore.activeTranscript(in: directory)))?.engine == "parakeet")
    }

    @Test("Already resolved voices need no extra LLM call")
    func noConflict() async throws {
        var voices = try #require(fixture().primary.voices)
        voices.name("A", "Costin")
        let result = try await SpeakerIdentityReview.resolve(voices, transcript: fixture().primary.transcript,
            suggestions: [], using: .claude) { _, _, _ in
                Issue.record("No conflicts to resolve")
                throw CancellationError()
            }
        #expect(result == voices)
    }

    @Test("Long recordings supply bounded excerpts across the timeline")
    func longContext() throws {
        let voices = try #require(fixture().primary.voices)
        let lines = (0..<4_000).map {
            Utterance(start: Double($0 * 5), end: Double($0 * 5 + 4), text: "Passage \($0)", speaker: .voice("A"))
        }
        let transcript = Transcript(utterances: lines, language: "en", engine: "parakeet")
        let input = try SpeakerIdentityReview.input(voices, transcript: transcript, suggestions: [])
        #expect(input.utf8.count < 100_000)
        #expect(input.contains("Passage 0") && input.contains("Passage 3999"))
    }

    @Test("Live identity review resolves a conflicting voice match from self-introduction",
          .enabled(if: ProcessInfo.processInfo.environment["ANYREC_LIVE_REVIEW_TEST"] == "1"))
    func liveResolution() async throws {
        let candidates = fixture()
        let result = try await SpeakerIdentityReview.resolve(candidates.primary.voices,
            transcript: candidates.primary.transcript, suggestions: [], using: .claude) {
                try await LLMClient.complete(instructions: $0, text: $1, using: $2)
            }
        #expect(result?.names == ["A": "Costin"])
        #expect(result?.voices[0].identityEvidence?.conflict == false)
    }

    private var wording: String {
        #"{"lines":[{"id":0,"text":"I'm Costin. I'll share my screen."},{"id":1,"text":"This is the dashboard."}],"suggestions":[{"letter":"A","name":"Costin","quote":"I'm Costin","line":0}],"speakerChanges":[]}"#
    }

    private func decision(_ name: String) -> String {
        "{\"identities\":[{\"letter\":\"A\",\"name\":\"\(name)\",\"reason\":\"The speaker introduces himself as Costin.\"}]}"
    }

    private func fixture() -> TranscriptionCandidates {
        let lines = [Utterance(start: 0, end: 4, text: "I'm Costin. I'll share my screen.", speaker: .voice("A")),
                     Utterance(start: 4, end: 8, text: "This is the dashboard.", speaker: .voice("A"))]
        let transcript = Transcript(utterances: lines, language: "en", engine: "parakeet")
        var voice = RecordingVoices.Voice(letter: "A", print: [1, 0], sample: lines[0].text, start: 0, end: 4)
        voice.identityEvidence = .init(callNames: ["Costin"], voiceprintName: "Alex", conflict: true)
        return TranscriptionCandidates(primary: .init(transcript: transcript, voices: .init(voices: [voice])),
                                       transcripts: [transcript], failures: [])
    }

    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-identity-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return OutputPlan(directory: directory).directory
    }
}
