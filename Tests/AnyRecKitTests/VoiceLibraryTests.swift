import Foundation
import Testing

@testable import AnyRecKit

@Suite("VoiceLibrary")
struct VoiceLibraryTests {
    private let john: Voiceprint = [1, 0, 0, 0]
    private let johnAgain: Voiceprint = [0.9, 0.1, 0, 0]
    private let sarah: Voiceprint = [0, 1, 0, 0]

    @Test("names the nearest person, and only when near enough")
    func match() {
        var library = VoiceLibrary()
        library.enroll("John", john)
        library.enroll("Sarah", sarah)

        #expect(library.match(johnAgain)?.name == "John")
        #expect(library.match([0, 0, 1, 0]) == nil)
        #expect(library.match([0.6, 0.6, 0, 0])?.name == "John")
    }

    @Test("files a second print under the same name rather than a second person")
    func enrollTwice() {
        var library = VoiceLibrary()
        library.enroll("John", john)
        library.enroll(" John ", johnAgain)
        library.enroll("", sarah)

        #expect(library.names == ["John"])
        #expect(library.people[0].prints.count == 2)
    }

    @Test("cosine similarity: same direction is 1, orthogonal is 0, mismatched is 0")
    func similarity() {
        #expect(VoiceLibrary.similarity(john, [2, 0, 0, 0]) == 1)
        #expect(VoiceLibrary.similarity(john, sarah) == 0)
        #expect(VoiceLibrary.similarity(john, [1, 0]) == 0)
    }

    @Test("comes back from disk as it went, one file per person, forgotten ones removed")
    func roundTrip() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appendingPathComponent("anyrec-voices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var library = VoiceLibrary()
        library.enroll("John", john)
        library.enroll("Sarah", sarah)
        try library.save(to: directory)

        #expect(VoiceLibrary.load(from: directory) == library)

        library.forget("Sarah")
        try library.save(to: directory)

        #expect(VoiceLibrary.load(from: directory).names == ["John"])
        #expect(VoiceLibrary.load(from: directory.appendingPathComponent("missing")).isEmpty)
    }

    @Test("keeps a name out of the path separators")
    func fileName() {
        #expect(VoiceLibrary.fileName(for: "A/B:C") == "A-B-C.json")
    }

    @Test("a colleague's file adds the people it does not have and the prints it does not have")
    func merge() throws {
        var mine = VoiceLibrary(people: [.init(name: "Ana", prints: [[1, 0]])])
        let theirs = VoiceLibrary(people: [
            .init(name: "Ana", prints: [[1, 0], [0, 1]]), .init(name: "Mihai", prints: [[0.5, 0.5]]),
            .init(name: "", prints: [[1, 1]]),
        ])

        let added = try mine.merge(try theirs.exported())

        #expect(added.people == 1 && added.prints == 2)
        #expect(mine.names == ["Ana", "Mihai"])
        #expect(mine.people[0].prints.count == 2)
        #expect(try mine.merge(try theirs.exported()) == (0, 0))
    }

}

@Suite("RecordingVoices")
struct RecordingVoicesTests {
    private func voices() -> RecordingVoices {
        RecordingVoices(voices: [
            .init(letter: "A", print: [1, 0], sample: "Let's move on.", start: 10, end: 12),
            .init(letter: "B", print: [0, 1], sample: "Okay.", start: 20, end: 21, name: "Sarah"),
        ])
    }

    @Test("names a letter, and an empty name un-names it")
    func naming() {
        var voices = voices()
        voices.name("A", " John ")

        #expect(voices.names == ["A": "John", "B": "Sarah"])
        #expect(voices.unnamed.isEmpty)

        voices.name("B", "")
        #expect(voices.unnamed.map(\.letter) == ["B"])
    }

    @Test("renames a transcript's letters and leaves everything else alone")
    func renamesTranscript() {
        let transcript = Transcript(
            utterances: [
                Utterance(start: 0, end: 1, text: "Hi", speaker: .voice("A")),
                Utterance(start: 1, end: 2, text: "Hello", speaker: .voice("B")),
                Utterance(start: 2, end: 3, text: "Yes", speaker: .me),
            ], language: "en", engine: "whisper")

        let named = transcript.named(["A": "John"])

        #expect(named.utterances.map(\.speaker) == [.named("John"), .voice("B"), .me])
        #expect(named.turns.map(\.speaker.label) == ["John", "Speaker B", "Me"])
    }

    @Test("comes back from disk as it went")
    func roundTrip() throws {
        let url = URL(filePath: NSTemporaryDirectory())
            .appendingPathComponent("anyrec-recording-voices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let voices = voices()

        try voices.write(to: url)

        #expect(RecordingVoices.read(url) == voices)
    }
}
