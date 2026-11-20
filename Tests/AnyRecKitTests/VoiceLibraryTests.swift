import Foundation
import Testing

@testable import AnyRecKit

@Suite("VoiceLibrary")
struct VoiceLibraryTests {
    private let john: Voiceprint = [1, 0, 0, 0]
    private let johnAgain: Voiceprint = [0.9, 0.1, 0, 0]
    private let sarah: Voiceprint = [0, 1, 0, 0]

    @Test("a directory's \"Last, First (Tag)\" answers for the person known as \"First Last\"")
    func directoryOrder() {
        let claudiu = VoiceLibrary.Person(name: "Claudiu", prints: [], aliases: ["Claudiu Barbura"])
        #expect(claudiu.answers(to: "Barbura, Claudiu (Contractor)"))
        #expect(claudiu.answers(to: "Barbura, Claudiu"))
        #expect(!claudiu.answers(to: "Barbura, Ana (Contractor)"))
        let stored = VoiceLibrary.Person(name: "Claudiu", prints: [], aliases: ["Barbura, Claudiu (Contractor)"])
        #expect(stored.answers(to: "Claudiu Barbura"))
    }

    @Test("another person's call name, written the directory's way, is never filed under the owner")
    func ownerKeepsOwnName() {
        var library = VoiceLibrary(people: [
            .init(name: "Doru", prints: [john], aliases: ["Doru Chiulan"], isOwner: true),
            .init(name: "Claudiu", prints: [sarah], aliases: ["Claudiu Barbura"]),
        ])
        let noted = library.noteCallName("Barbura, Claudiu (Contractor)", for: "Doru")
        let aliased = library.addAlias("Barbura, Claudiu (Contractor)", to: "Doru")
        #expect(!noted)
        #expect(!aliased)
        let doru = library.people.first { $0.name == "Doru" }
        #expect(doru?.aliases == ["Doru Chiulan"])
        #expect(doru?.displayName == nil)
    }

    @Test("names the nearest person, and only when near enough")
    func match() {
        var library = VoiceLibrary()
        library.enroll("John", john)
        library.enroll("Sarah", sarah)

        #expect(library.match(johnAgain)?.name == "John")
        #expect(library.match([0, 0, 1, 0]) == nil)
        /// Equally close to two people names nobody; clearly closer to one names them.
        #expect(library.match([0.6, 0.6, 0, 0]) == nil)
        #expect(library.match([0.7, 0.5, 0, 0])?.name == "John")
    }

    @Test("files a second print under the same name rather than a second person")
    func enrollTwice() {
        var library = VoiceLibrary()
        library.enroll("John", john)
        /// A different condition of the same voice; a near-copy would not be added twice.
        library.enroll(" John ", [0.7, 0.7, 0, 0])
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

@Suite("VoiceLibrary people")
struct VoiceLibraryPeopleTests {
    @Test("files written before aliases and the owner flag read with neither")
    func oldFiles() throws {
        let person = try JSONDecoder().decode(VoiceLibrary.Person.self, from: Data(#"{"name":"Alex","prints":[[1,0]]}"#.utf8))
        #expect(person.aliases.isEmpty && !person.isOwner && person.displayName == nil)
        #expect(person.shownName == "Alex")
        var library = VoiceLibrary()
        try library.merge(Data(#"[{"name":"Alex","prints":[[1,0]]}]"#.utf8))
        #expect(library.names == ["Alex"])
    }

    @Test("an alias belongs to one person; a display name already someone else's is refused")
    func aliases() {
        var library = VoiceLibrary(people: [.init(name: "Alex", prints: [[1, 0]]), .init(name: "Maria", prints: [[0, 1]])])
        let added = library.addAlias("Alex Ionescu", to: "Alex")
        let repeated = library.addAlias("alex  ionescu", to: "Alex")
        let taken = library.addAlias("Alex Ionescu", to: "Maria")
        #expect(added && !repeated && !taken)
        #expect(library.person(answering: "ALEX IONESCU")?.name == "Alex")
        #expect(library.person(answering: "Maria")?.name == "Maria")
        #expect(library.person(answering: "Nobody") == nil)
        #expect(library.people[0].prints == [[1, 0]])
    }

    @Test("a call window's name becomes the name shown, and the latest one wins")
    func callName() throws {
        var library = VoiceLibrary(people: [.init(name: "Alex", prints: [[1, 0]]), .init(name: "Maria", prints: [[0, 1]])])
        let first = library.noteCallName("Alex Ionescu", for: "Alex")
        #expect(first)
        #expect(library.people[0].shownName == "Alex Ionescu" && library.people[0].aliases == ["Alex Ionescu"])
        let again = library.noteCallName("Alex Ionescu", for: "Alex")
        let savedName = library.noteCallName("ALEX", for: "Alex")
        let someoneElse = library.noteCallName("Maria", for: "Alex")
        #expect(!again && !savedName && !someoneElse)
        let newer = library.noteCallName("A. Ionescu", for: "Alex")
        #expect(newer)
        #expect(library.people[0].displayName == "A. Ionescu")
        #expect(library.people[0].aliases == ["Alex Ionescu", "A. Ionescu"])
        #expect(library.people[0].prints == [[1, 0]])

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try library.save(to: folder)
        #expect(VoiceLibrary.load(from: folder).people[0].displayName == "A. Ionescu")

        var colleague = VoiceLibrary()
        try colleague.merge(try library.exported())
        #expect(colleague.people[0].displayName == "A. Ionescu")
        var mine = VoiceLibrary(people: [.init(name: "Alex", prints: [[1, 0]], aliases: ["Alexandru"], displayName: "Alexandru")])
        try mine.merge(try library.exported())
        #expect(mine.people[0].displayName == "Alexandru")
    }

    @Test("naming a voice with a name someone already answers to adds the print to them")
    func enrollByShownName() {
        var library = VoiceLibrary(people: [
            .init(name: "Alex", prints: [[1, 0]], aliases: ["Alex Ionescu"], displayName: "Alex Ionescu"),
            .init(name: "Maria", prints: [[0, 1]]),
        ])
        library.enroll("alex ionescu", [0.8, 0.6])
        library.enroll("Sam", [0.5, 0.5])
        #expect(library.names == ["Alex", "Maria", "Sam"])
        #expect(library.people[0].prints == [[1, 0], [0.8, 0.6]])
    }

    @Test("the owner flag is this library's; exports carry aliases but not who owns them")
    func owner() throws {
        var library = VoiceLibrary(people: [.init(name: "Alex", prints: [[1, 0]], aliases: ["Alex Ionescu"])])
        library.setOwner("Alex")
        #expect(library.owner?.name == "Alex")
        var colleague = VoiceLibrary()
        try colleague.merge(try library.exported())
        #expect(colleague.owner == nil)
        #expect(colleague.people[0].aliases == ["Alex Ionescu"])
    }

    @Test("the import panel accepts the type Finder gives a .anyrecvoices file")
    func importType() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("AnyRec Voices.\(VoiceLibrary.fileExtension)")
        try VoiceLibrary(people: [.init(name: "Ana", prints: [[1, 0]])]).exported().write(to: file)

        let type = try #require(try file.resourceValues(forKeys: [.contentTypeKey]).contentType)
        #expect(VoiceLibrary.importTypes.contains { type.conforms(to: $0) })
        #expect(VoiceLibrary.importTypes.contains(.json))
    }

    @Test("an imported person matches whoever here answers to one of their names")
    func mergeByAlias() throws {
        var mine = VoiceLibrary(people: [
            .init(name: "Andrei Lungu", prints: [[1, 0]], aliases: ["Andi"]),
            .init(name: "Maria", prints: [[0, 1]]),
        ])
        let theirs = VoiceLibrary(people: [
            /// Like Andrei's own print but not a near-copy of it (`duplicatePrint`).
            .init(name: "Andi", prints: [[0.7, 0.7]], aliases: ["Andrei L."], displayName: "Andrei L."),
            .init(name: "Mara", prints: [[0.5, 0.5]], aliases: ["Maria", "Andi"]),
        ])

        let added = try mine.merge(try theirs.exported())

        #expect(mine.names == ["Andrei Lungu", "Mara", "Maria"], "names pointing at two people match nobody")
        #expect(added.people == 1 && added.prints == 2)
        #expect(mine.people[0].prints == [[1, 0], [0.7, 0.7]])
        #expect(mine.people[0].aliases.contains("Andrei L."))
        #expect(mine.people[0].displayName == "Andrei L.")
    }
}
