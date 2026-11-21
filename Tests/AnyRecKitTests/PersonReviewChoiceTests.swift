import Foundation
import Testing
@testable import AnyRecKit

@Suite("Choosing someone else")
struct PersonReviewChoiceTests {
    private func recording(_ speakers: [Speaker]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = speakers.enumerated().map { index, speaker in
            Utterance(start: Double(index), end: Double(index + 1), text: "Line \(index)", speaker: speaker)
        }
        try TranscriptStore.publish(Transcript(utterances: lines, language: "en", engine: "test"), voices: nil, in: directory)
        return directory
    }

    @Test("Fix All respects a different person chosen for an individual suggestion")
    func overrideThenFixAll() throws {
        let directory = try recording([.others, .others, .me])
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(TranscriptStore.selection(in: directory)?.transcript)
        let fixes = [0, 1].map {
            SpeakerCorrection(line: $0, from: .others, to: .me, reason: "Reply", quote: "Line", evidenceLine: 2)
        }
        let wording = WordingLayer(source: source, lineCount: 3, provider: .codex, changes: [], compared: [],
                                   suggestions: [], speakerChanges: fixes, failures: [], batchFailures: [], batchCount: 1, notes: [])
        try TranscriptStore.publishWording(wording, voices: nil, in: directory)
        try TranscriptSpeakerReview.apply(fixes[0], as: .named("Taylor Reed"), in: directory)
        #expect(RecordingTranscript.read(in: directory)?.pendingSpeakerChanges == [fixes[1]])
        try TranscriptSpeakerReview.apply(fixes, in: directory)
        let current = try #require(RecordingTranscript.read(in: directory))
        #expect(current.transcript.utterances.map(\.speaker) == [.named("Taylor Reed"), .me, .me])
        #expect(current.pendingSpeakerChanges.isEmpty)
    }

    @Test("a mixed voice can be sorted between Me, an existing voice and a new name")
    func sortTargets() throws {
        let directory = try recording([.voice("A"), .voice("A"), .voice("A"), .voice("B")])
        defer { try? FileManager.default.removeItem(at: directory) }
        let choices: [Int: Speaker] = [0: .me, 1: .voice("B"), 2: .named("Taylor Reed")]
        try SpeakerEditing.sort(.voice("A"), picks: choices, in: directory)
        #expect(RecordingTranscript.read(in: directory)?.named.utterances.map(\.speaker) == [.me, .voice("B"), .named("Taylor Reed"), .voice("B")])
        #expect(throws: (any Error).self) { try SpeakerEditing.sort(.voice("A"), picks: choices, in: directory) }
    }

    @Test("sorting a mixed voice keeps the majority name and closes the question")
    func sortedVoice() throws {
        let directory = try recording([.voice("A"), .voice("A"), .voice("A")])
        defer { try? FileManager.default.removeItem(at: directory) }
        var voice = RecordingVoices.Voice(letter: "A", print: [], sample: "", start: 0, end: 3)
        voice.identityEvidence = SpeakerIdentityEvidence(callNames: [], voiceprintName: nil, conflict: false)
        voice.identityEvidence?.fusedNames = ["Sam", "Alex"]
        try TranscriptStore.updateSpeakers(in: directory) { layer, _ in
            layer.voices = RecordingVoices(voices: [voice])
        }
        try SpeakerEditing.sort(.voice("A"), picks: [0: .me, 1: .named("Sam"), 2: .named("Sam")], in: directory)
        let current = try #require(RecordingTranscript.read(in: directory))
        #expect(current.named.utterances.map(\.speaker) == [.me, .named("Sam"), .named("Sam")])
        #expect(current.voices?.voices.first?.name == "Sam")
        let people = try #require(RecordingSpeakers.read(in: directory, library: VoiceLibrary(), participants: nil))
        #expect(people.row(for: .voice("A"))?.fusedNames == [])
        #expect(current.voices?.voices.first?.identityEvidence?.fusedNames == ["Sam", "Alex"])
    }

    @Test("a transcript with only unclaimed lines stays in Unnamed Voices until the last one is assigned")
    func unclaimedOnly() throws {
        let directory = try recording([.others, .others, .me])
        defer { try? FileManager.default.removeItem(at: directory) }
        try SpeakerEditing.reassign([0], to: .me, in: directory)
        let entry = RecordingLibrary.entry(at: directory)
        #expect(entry.unnamedVoices == 0 && entry.hasUnnamedSpeech)
        try SpeakerEditing.reassign([1], to: .named("Taylor Reed"), in: directory)
        #expect(!RecordingLibrary.entry(at: directory).hasUnnamedSpeech)
    }
}
