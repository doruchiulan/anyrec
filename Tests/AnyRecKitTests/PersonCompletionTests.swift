import Foundation
import Testing

@testable import AnyRecKit

@Suite("Typed names complete from the library")
struct PersonCompletionTests {
    private func person(_ name: String, prints: [Voiceprint] = [[1, 0]], aliases: [String] = [], owner: Bool = false,
                        shown: String? = nil) -> VoiceLibrary.Person {
        .init(name: name, prints: prints, aliases: aliases, isOwner: owner, displayName: shown)
    }

    private func voice(_ letter: String, _ name: String? = nil, print: Voiceprint = []) -> RecordingVoices.Voice {
        .init(letter: letter, print: print, sample: "Hello", start: 0, end: 5, name: name)
    }

    private func speakers(_ voices: [RecordingVoices.Voice], library: VoiceLibrary) -> RecordingSpeakers {
        let lines = voices.enumerated().map {
            Utterance(start: Double($0.offset) * 10, end: Double($0.offset) * 10 + 5, text: "Hello", speaker: .voice($0.element.letter))
        }
        return RecordingSpeakers.build(lines: lines, voices: RecordingVoices(voices: voices), suggestions: [], corrections: [],
                                       participants: nil, info: nil, library: library)
    }

    @Test("the start of a word comes before a match inside one")
    func prefixBeforeSubstring() {
        let library = VoiceLibrary(people: [person("Bogdan"), person("Ioana"), person("Mihai Andrei"), person("Ana Pop"), person("Radu")])
        let names = PersonCompletion.suggestions("an", in: library, print: []).map(\.shownName)
        #expect(names == ["Ana Pop", "Mihai Andrei", "Bogdan", "Ioana"])
    }

    @Test("a whole name comes first, and two typed words match across a name's words")
    func exactFirst() {
        let library = VoiceLibrary(people: [person("Ana Maria"), person("Ana")])
        let result = PersonCompletion.suggestions("ana", in: library, print: [])
        #expect(result.map(\.shownName) == ["Ana", "Ana Maria"])
        #expect(result.map(\.exact) == [true, false])
        #expect(PersonCompletion.suggestions("ana  m", in: library, print: []).map(\.shownName) == ["Ana Maria"])
    }

    @Test("case and diacritics are ignored: ș, ş and s are one letter, ă and a are one")
    func diacritics() {
        #expect(PersonCompletion.fold("ș") == "s" && PersonCompletion.fold("Ş") == "s")
        #expect(PersonCompletion.fold("Țurcan  Ă") == "turcan a")
        let library = VoiceLibrary(people: [person("Ștefan Ionescu"), person("Răzvan"), person("Mihaela Ţurcan")])
        #expect(PersonCompletion.suggestions("stef", in: library, print: []).map(\.shownName) == ["Ștefan Ionescu"])
        #expect(PersonCompletion.suggestions("ŞTE", in: library, print: []).map(\.shownName) == ["Ștefan Ionescu"])
        #expect(PersonCompletion.suggestions("raz", in: library, print: []).map(\.shownName) == ["Răzvan"])
        #expect(PersonCompletion.suggestions("țurcan", in: library, print: []).map(\.shownName) == ["Mihaela Ţurcan"])
        let exact = PersonCompletion.suggestions("stefan ionescu", in: library, print: [])
        #expect(exact.first?.exact == true && exact.first?.matched == "Ștefan Ionescu")
    }

    @Test("aliases and display names match, and say which name did")
    func aliases() {
        let library = VoiceLibrary(people: [
            person("Andi", aliases: ["Andrei Lungu"], shown: "Andrei Lungu"),
            person("Dan", aliases: ["Daniel Popescu"]),
        ])
        let byShown = PersonCompletion.suggestions("and", in: library, print: [])
        #expect(byShown.map(\.savedName) == ["Andi"])
        #expect(byShown[0].shownName == "Andrei Lungu" && byShown[0].alsoKnownAs == nil)
        let bySaved = PersonCompletion.suggestions("ANDI", in: library, print: [])
        #expect(bySaved[0].matched == "Andi" && bySaved[0].alsoKnownAs == "Andi" && bySaved[0].exact)
        #expect(PersonCompletion.suggestions("lun", in: library, print: []).first?.matched == "Andrei Lungu")
        let byAlias = PersonCompletion.suggestions("pope", in: library, print: [])
        #expect(byAlias.map(\.shownName) == ["Dan"] && byAlias[0].alsoKnownAs == "Daniel Popescu")
        #expect(PersonCompletion.suggestions("zz", in: library, print: []).isEmpty)
    }

    @Test("the owner and people already named on another voice are left out, unless typed exactly")
    func exclusions() {
        let library = VoiceLibrary(people: [person("Ana"), person("Andrei"), person("Anastasia", owner: true), person("Andreea")])
        let result = speakers([voice("A", "Ana"), voice("B"), voice("C", "Andreea")], library: library)
        #expect(result.completions(for: .voice("B"), typing: "an").map(\.savedName) == ["Andrei"])
        #expect(result.completions(for: .voice("B"), typing: "ANA").map(\.savedName) == ["Ana"])
        #expect(result.completions(for: .voice("B"), typing: "anastasia").map(\.savedName) == ["Anastasia"])
        /// Whoever this voice already is is not offered back to it either.
        #expect(result.completions(for: .voice("A"), typing: "an").map(\.savedName) == ["Andrei"])
        #expect(result.person(for: .voice("B"), typed: "ana")?.savedName == "Ana")
        #expect(result.person(for: .voice("B"), typed: "an") == nil)
    }

    @Test("a person another voice carries by their shown name is taken")
    func shownNameTaken() {
        /// "Andrei Lungu" is on voice A by the name the call showed, so Andi is taken.
        let library = VoiceLibrary(people: [person("Andi", aliases: ["Andrei Lungu"], shown: "Andrei Lungu"), person("Andreea")])
        let result = speakers([voice("A", "Andrei Lungu"), voice("B")], library: library)
        #expect(result.completions(for: .voice("B"), typing: "and").map(\.savedName) == ["Andreea"])
    }

    @Test("with nothing typed, the saved voices nearest this one, with no threshold")
    func emptyTextBySimilarity() {
        let library = VoiceLibrary(people: [
            person("Far", prints: [[0, 1]]), person("Near", prints: [[1, 0.1]]), person("Middle", prints: [[0.5, 0.5]]),
            person("Me", prints: [[1, 0]], owner: true), person("Nobody", prints: []),
        ])
        let result = speakers([voice("A", print: [1, 0]), voice("B")], library: library)
        #expect(result.completions(for: .voice("A"), typing: "").map(\.savedName) == ["Near", "Middle", "Far"])
        #expect(result.completions(for: .voice("A"), typing: "  ", limit: 2).map(\.savedName) == ["Near", "Middle"])
        #expect(result.completions(for: .voice("B"), typing: "").isEmpty)
    }

    @Test("typed matches in the same tier are ordered by how close the voice is")
    func tierBySimilarity() {
        let library = VoiceLibrary(people: [person("Ana Far", prints: [[0, 1]]), person("Ana Near", prints: [[1, 0]])])
        let result = speakers([voice("A", print: [1, 0])], library: library)
        #expect(result.completions(for: .voice("A"), typing: "ana").map(\.savedName) == ["Ana Near", "Ana Far"])
    }

    // MARK: Picking

    private func recording(_ voices: [RecordingVoices.Voice]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-complete-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        /// Long enough for a print worth keeping (`VoiceLibrary.minimumSeconds`).
        let lines = voices.enumerated().map {
            Utterance(start: Double($0.offset) * 40, end: Double($0.offset) * 40 + 30, text: "Hello", speaker: .voice($0.element.letter))
        }
        try TranscriptStore.publish(Transcript(utterances: lines, language: "en", engine: "parakeet"),
                                    voices: RecordingVoices(voices: voices), in: folder)
        return folder
    }

    @Test("picking a suggestion files the print under that person and shows their shown name; no new record")
    func pickingFilesUnderPerson() throws {
        /// Close enough to Andi's own print to join it rather than wait (`probationFloor`).
        var b = voice("B", print: [0.6, 0.8])
        b.identityEvidence = { var e = SpeakerIdentityEvidence(callNames: ["A. Lungu"], voiceprintName: nil, conflict: false); e.callName = "A. Lungu"; return e }()
        let folder = try recording([voice("A", print: [1, 0]), b])
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = folder.appendingPathComponent("library")
        try VoiceLibrary(people: [person("Andi", prints: [[0.9, 0.1]], aliases: ["Andrei Lungu"], shown: "Andrei Lungu")])
            .save(to: library)

        let speakers = try #require(RecordingSpeakers.read(in: folder, library: VoiceLibrary.load(from: library)))
        let picked = try #require(speakers.completions(for: .voice("B"), typing: "and").first)
        try SpeakerEditing.name(.voice("B"), picked.shownName, in: folder, person: picked.savedName, library: library)

        let loaded = VoiceLibrary.load(from: library)
        #expect(loaded.people.map(\.name) == ["Andi"])
        #expect(loaded.people[0].prints.count == 2)
        #expect(loaded.people[0].aliases.contains("A. Lungu"))
        #expect(RecordingVoices.read(in: folder)?.voices.first { $0.letter == "B" }?.name == "Andrei Lungu")
    }

    @Test("a picked person is filed under their saved name even when another person is shown under the same name")
    func pickingAmbiguousShownName() throws {
        /// A print neither person has yet: a print already there is not filed twice.
        let folder = try recording([voice("A", print: [0.8, 0.6])])
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = folder.appendingPathComponent("library")
        try VoiceLibrary(people: [person("Ana Pop", shown: "Ana"), person("Ana Ionescu", shown: "Ana")]).save(to: library)

        let speakers = try #require(RecordingSpeakers.read(in: folder, library: VoiceLibrary.load(from: library)))
        #expect(speakers.person(for: .voice("A"), typed: "Ana") == nil)
        let picked = try #require(speakers.completions(for: .voice("A"), typing: "ana").first { $0.savedName == "Ana Ionescu" })
        try SpeakerEditing.name(.voice("A"), picked.shownName, in: folder, person: picked.savedName, library: library)

        let loaded = VoiceLibrary.load(from: library)
        #expect(loaded.people.map(\.name).sorted() == ["Ana Ionescu", "Ana Pop"])
        #expect(loaded.people.first { $0.name == "Ana Ionescu" }?.prints.count == 2)
        #expect(loaded.people.first { $0.name == "Ana Pop" }?.prints.count == 1)
    }

    @Test("a name nobody answers to is a new person")
    func newPerson() throws {
        /// Unlike Andi's print: a voice that sounds like someone already known is not filed
        /// under a new name (`VoiceLibrary.Admission.soundsLike`).
        let folder = try recording([voice("A", print: [0, 1])])
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = folder.appendingPathComponent("library")
        try VoiceLibrary(people: [person("Andi")]).save(to: library)

        let speakers = try #require(RecordingSpeakers.read(in: folder, library: VoiceLibrary.load(from: library)))
        #expect(speakers.person(for: .voice("A"), typed: "Radu") == nil)
        #expect(speakers.completions(for: .voice("A"), typing: "Radu").isEmpty)
        try SpeakerEditing.name(.voice("A"), "Radu", in: folder, library: library)
        #expect(VoiceLibrary.load(from: library).people.map(\.name) == ["Andi", "Radu"])
    }
}
