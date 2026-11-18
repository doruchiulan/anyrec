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
        let outcome = try await TranscriptPass.publish(candidates, in: directory, options: options, library: { VoiceLibrary() }, progress: { _ in }) { _, text, _ in
            if text.contains("\"conflicts\"") {
                #expect(text.contains("Costin") && text.contains("Alex") && text.contains("I'm Costin"))
                #expect(!text.contains("\"print\""))
                return self.decision("Costin")
            }
            return self.wording
        }
        guard case .written(let files, _, let voices, _) = outcome else { Issue.record("Expected transcript"); return }
        #expect(voices?.names == ["A": "Costin"])
        #expect(voices?.voices[0].print == candidates.primary.voices?.voices[0].print)
        #expect(RecordingVoices.read(in: directory) == voices)
        #expect(Transcript.read(files[1])?.utterances == candidates.primary.transcript.utterances)
        #expect(try String(contentsOf: files[0], encoding: .utf8).contains("Costin"))
        let evidence = try #require(voices?.voices[0].identityEvidence)
        #expect(!evidence.conflict && evidence.callNames == ["Costin"] && evidence.voiceprintName == "Alex")
        #expect(evidence.resolution?.name == "Costin" && evidence.resolution?.provider == options.reviewProvider)
        #expect(evidence.resolution?.reason == "The speaker introduces himself as Costin.")
        #expect(RecordingTranscript.read(in: directory)?.nameSuggestions.isEmpty == true)
        let stored = RecordingLayout(directory: directory).files(in: .transcripts)
        let layers = stored.filter { $0.lastPathComponent.hasPrefix("speakers-") }
            .compactMap { try? JSONDecoder().decode(SpeakerLayer.self, from: Data(contentsOf: $0)) }
        #expect(layers.count == 2)
        #expect(layers.contains { $0.voices == candidates.primary.voices })
    }

    @Test("The reviewer can keep the saved voice name instead of the call indicator")
    func keepsVoiceprint() throws {
        let voices = try #require(fixture().primary.voices)
        let result = try SpeakerIdentityReview.apply(decision("Alex"), to: voices, provider: .claude)
        #expect(result.names == ["A": "Alex"])
        #expect(result.voices[0].identityEvidence?.conflict == false)
    }

    @Test("A saved name the reviewer keeps is shown as the display name learned for that person")
    func keptVoiceprintShowsLearnedName() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = TranscriptionOptions()
        options.review = true
        let library = VoiceLibrary(people: [
            .init(name: "Alex", prints: [[1, 0]], aliases: ["Alex Ionescu"], displayName: "Alex Ionescu"),
            .init(name: "Costin", prints: [[0, 1]]),
        ])
        let outcome = try await TranscriptPass.publish(fixture(), in: directory, options: options, library: { library },
                                                       progress: { _ in }) { _, text, _ in
            text.contains("\"conflicts\"") ? self.decision("Alex") : self.wording
        }
        guard case .written(_, _, let voices, _) = outcome else { Issue.record("Expected transcript"); return }
        #expect(voices?.names == ["A": "Alex Ionescu"])
        #expect(voices?.voices[0].identityEvidence?.resolution?.name == "Alex")
        #expect(RecordingTranscript.read(in: directory)?.named.utterances.first?.speaker == .named("Alex Ionescu"))
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
        _ = try await TranscriptPass.publish(fixture(), in: directory, options: TranscriptionOptions(), library: { VoiceLibrary() }, progress: { _ in }) { _, _, _ in
            Issue.record("Review must remain opt-in")
            throw CancellationError()
        }
        #expect(RecordingVoices.read(in: directory) == fixture().primary.voices)
    }

    @Test("An invalid identity response keeps both candidates and the reviewed wording")
    func failedResolution() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = TranscriptionOptions()
        options.review = true
        _ = try await TranscriptPass.publish(fixture(), in: directory, options: options, library: { VoiceLibrary() }, progress: { _ in }) { _, input, _ in
            input.contains("\"conflicts\"") ? self.decision("Invented") : self.wording
        }
        #expect(RecordingVoices.read(in: directory) == fixture().primary.voices)
        #expect(RecordingTranscript.read(in: directory)?.reviewFailures.isEmpty == false)
        #expect(RecordingTranscript.read(in: directory)?.transcript.engine == "reviewed")
    }

    @Test("Names are resolved even when no wording batch could be used")
    func resolvesWithoutWording() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = TranscriptionOptions()
        options.review = true
        let outcome = try await TranscriptPass.publish(fixture(), in: directory, options: options, library: { VoiceLibrary() }, progress: { _ in }) { _, input, _ in
            input.contains("\"conflicts\"") ? self.decision("Costin") : "not a review"
        }
        guard case .written(_, let notes, let voices, _) = outcome else { Issue.record("Expected transcript"); return }
        #expect(voices?.names == ["A": "Costin"])
        #expect(notes.contains { $0.contains("Transcript review failed") })
        #expect(RecordingTranscript.read(in: directory)?.transcript.engine == "parakeet")
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
        #"{"changes":[{"id":0,"text":"I'm Costin. I'll share my screen."},{"id":1,"text":"This is the dashboard."}],"suggestions":[{"letter":"A","name":"Costin","quote":"I'm Costin","line":0}],"speakerChanges":[]}"#
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
