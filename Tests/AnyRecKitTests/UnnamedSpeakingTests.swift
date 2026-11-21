import Foundation
import Testing

@testable import AnyRecKit

@Suite("Unnamed voices")
struct UnnamedSpeakingTests {
    @Test("a voice with no name counts only while it still has lines")
    func countsOnlyVoicesWithLines() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-unnamed-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lines = [Utterance(start: 0, end: 4, text: "Hello", speaker: .voice("A")),
                     Utterance(start: 4, end: 6, text: "Hi", speaker: .voice("B")),
                     Utterance(start: 6, end: 9, text: "Shall we start?", speaker: .voice("B"))]
        let voices = RecordingVoices(voices: [.init(letter: "A", print: [], sample: "", start: 0, end: 4, name: "Alex Morgan"),
                                              .init(letter: "B", print: [], sample: "", start: 4, end: 9)])
        try TranscriptStore.publish(Transcript(utterances: lines, language: "en", engine: "parakeet"), voices: voices, in: directory)
        #expect(RecordingTranscript.read(in: directory)?.unnamedSpeaking == 1)

        try SpeakerEditing.reassign([1, 2], to: .named("Sam Rivera"), in: directory)
        let current = try #require(RecordingTranscript.read(in: directory))
        #expect(current.voices?.unnamed.count == 1)
        #expect(current.unnamedSpeaking == 0)
    }
}
