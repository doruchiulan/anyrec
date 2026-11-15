import Foundation
import Testing

@testable import AnyRecKit

/// A voice named wrongly must not leave its print with the wrong person: renaming it or
/// giving it away takes back exactly what that naming filed, and giving it to Me files it
/// under the owner. Prints carry where they came from.
@Suite("Voiceprints taken back")
struct VoiceRetractionTests {
    private let owners: Voiceprint = [1, 0]
    private let anasOwn: Voiceprint = [0, 1]
    private let costis: Voiceprint = [0.6, 0.8]

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-retract-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return OutputPlan(directory: folder).directory
    }

    private func voice(_ letter: String, _ name: String? = nil, print: Voiceprint, callName: String? = nil) -> RecordingVoices.Voice {
        var voice = RecordingVoices.Voice(letter: letter, print: print, sample: "Hello", start: 0, end: 5, name: name)
        if let callName {
            var evidence = SpeakerIdentityEvidence(callNames: [callName], voiceprintName: nil, conflict: false)
            evidence.callName = callName
            voice.identityEvidence = evidence
        }
        return voice
    }

    /// A recording with Me, voice A (Costi's print) and voice B (the owner's own print, heard
    /// on the far end), and a library folder beside it.
    private func recording(
        _ people: [VoiceLibrary.Person], b: RecordingVoices.Voice? = nil
    ) throws -> (folder: URL, library: URL) {
        let folder = try folder()
        let library = folder.appendingPathComponent("library")
        try VoiceLibrary(people: people).save(to: library)
        let lines = [
            Utterance(start: 0, end: 4, text: "Hi", speaker: .me),
            Utterance(start: 5, end: 9, text: "Costi here", speaker: .voice("A")),
            Utterance(start: 10, end: 14, text: "Me again, through the speakers", speaker: .voice("B")),
            Utterance(start: 15, end: 19, text: "And again", speaker: .voice("B")),
        ]
        try TranscriptStore.publish(Transcript(utterances: lines, language: "en", engine: "parakeet"),
                                    voices: RecordingVoices(voices: [voice("A", "Costi", print: costis), b ?? voice("B", print: owners)]),
                                    in: folder)
        return (folder, library)
    }

    private func speakers(in folder: URL) -> [Speaker] {
        RecordingTranscript.read(in: folder)?.transcript.utterances.map(\.speaker) ?? []
    }

    private func person(_ name: String, in library: URL) -> VoiceLibrary.Person? {
        VoiceLibrary.load(from: library).people.first { $0.name == name }
    }

    // MARK: Giving a whole voice away

    @Test("a whole voice given to Call moves every line and takes its print back from the person it was wrongly named as")
    func giveToCall() throws {
        let (folder, library) = try recording([.init(name: "Ana", prints: [anasOwn])])
        defer { try? FileManager.default.removeItem(at: folder) }
        try SpeakerEditing.name(.voice("B"), "Ana", in: folder, library: library)
        #expect(person("Ana", in: library)?.prints == [anasOwn, owners])

        try SpeakerEditing.give(.voice("B"), to: .others, in: folder, library: library)
        #expect(speakers(in: folder) == [.me, .voice("A"), .others, .others])
        #expect(person("Ana", in: library)?.prints == [anasOwn])
        let b = RecordingVoices.read(in: folder)?.voices.first { $0.letter == "B" }
        #expect(b?.name == nil && b?.namedByOwner == nil && b?.filed == nil)
    }

    @Test("a whole voice given to another speaker moves every line to that speaker")
    func giveToAnotherSpeaker() throws {
        let (folder, library) = try recording([.init(name: "Costi", prints: [costis])])
        defer { try? FileManager.default.removeItem(at: folder) }
        try SpeakerEditing.name(.voice("B"), "Costi", in: folder, library: library)
        #expect(person("Costi", in: library)?.prints == [costis, owners])

        try SpeakerEditing.give(.voice("B"), to: .voice("A"), in: folder, library: library)
        #expect(speakers(in: folder) == [.me, .voice("A"), .voice("A"), .voice("A")])
        #expect(person("Costi", in: library)?.prints == [costis])
        /// The voice that received the lines keeps its name.
        #expect(RecordingVoices.read(in: folder)?.voices.first { $0.letter == "A" }?.name == "Costi")
    }

    @Test("given to Me, the print leaves the wrong person and joins the owner's record")
    func giveToMeWithOwner() throws {
        let (folder, library) = try recording([
            .init(name: "Ana", prints: [anasOwn]), .init(name: "Doru", prints: [[0.9, 0.1]], isOwner: true),
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        try SpeakerEditing.name(.voice("B"), "Ana", in: folder, library: library)

        try SpeakerEditing.give(.voice("B"), to: .me, in: folder, library: library)
        #expect(speakers(in: folder) == [.me, .voice("A"), .me, .me])
        #expect(person("Ana", in: library)?.prints == [anasOwn])
        let doru = try #require(person("Doru", in: library))
        #expect(doru.prints == [[0.9, 0.1], owners])
        #expect(doru.origin(ofPrint: 0) == nil)
        #expect(doru.origin(ofPrint: 1)?.recording == folder.lastPathComponent)
        #expect(RecordingVoices.read(in: folder)?.voices.first { $0.letter == "B" }?.filed?.person == "Doru")
    }

    @Test("given to Me with no owner, the print is filed nowhere")
    func giveToMeWithoutOwner() throws {
        let (folder, library) = try recording([.init(name: "Ana", prints: [anasOwn])])
        defer { try? FileManager.default.removeItem(at: folder) }
        try SpeakerEditing.name(.voice("B"), "Ana", in: folder, library: library)

        try SpeakerEditing.giveToMe(.voice("B"), in: folder, library: library)
        let saved = VoiceLibrary.load(from: library)
        #expect(saved.people.map(\.name) == ["Ana"])
        #expect(saved.people[0].prints == [anasOwn])
        #expect(!saved.people.contains { $0.prints.contains(owners) })
    }

    @Test("Me with remember keeps the owner's alias even when the earlier naming had filed the same one")
    func giveToMeRemembering() throws {
        let (folder, library) = try recording([], b: voice("B", print: owners, callName: "Doru Chiulan"))
        defer { try? FileManager.default.removeItem(at: folder) }
        try SpeakerEditing.name(.voice("B"), "Doru", in: folder, library: library)
        #expect(person("Doru", in: library)?.aliases == ["Doru Chiulan"])

        try SpeakerEditing.giveToMe(.voice("B"), in: folder,
                                    remember: OwnerToRemember(person: "Doru", shownName: "Doru", display: "Doru Chiulan"),
                                    library: library)
        let doru = try #require(person("Doru", in: library))
        #expect(doru.isOwner)
        #expect(doru.aliases == ["Doru Chiulan"])
        #expect(doru.prints == [owners])
    }

    @Test("giving away a voice nobody named leaves the library as it was")
    func giveUnnamed() throws {
        let people: [VoiceLibrary.Person] = [.init(name: "Ana", prints: [anasOwn, owners])]
        let (folder, library) = try recording(people)
        defer { try? FileManager.default.removeItem(at: folder) }
        try SpeakerEditing.give(.voice("B"), to: .others, in: folder, library: library)
        #expect(VoiceLibrary.load(from: library).people == people)
    }

    // MARK: Renaming

    @Test("renaming an owner-named voice takes exactly its print from the previous person and files it under the new one")
    func rename() throws {
        let (folder, library) = try recording([.init(name: "Ana", prints: [anasOwn, [0.2, 0.98]]), .init(name: "Mihai", prints: [])])
        defer { try? FileManager.default.removeItem(at: folder) }
        try SpeakerEditing.name(.voice("B"), "Ana", in: folder, library: library)
        try SpeakerEditing.name(.voice("B"), "Mihai", in: folder, library: library)

        #expect(person("Ana", in: library)?.prints == [anasOwn, [0.2, 0.98]])
        #expect(person("Mihai", in: library)?.prints == [owners])
        /// A person who was there before is kept, even emptied.
        try SpeakerEditing.name(.voice("B"), "Ana", in: folder, library: library)
        #expect(person("Mihai", in: library)?.prints == [])
    }

    @Test("a record the wrong naming made is removed once it is empty; one with something else in it stays")
    func madeByNaming() throws {
        let (folder, library) = try recording([.init(name: "Ana", prints: [anasOwn])])
        defer { try? FileManager.default.removeItem(at: folder) }
        try SpeakerEditing.name(.voice("B"), "Typo", in: folder, library: library)
        #expect(RecordingVoices.read(in: folder)?.voices.first { $0.letter == "B" }?.filed?.createdPerson == true)
        try SpeakerEditing.name(.voice("B"), "Ana", in: folder, library: library)
        #expect(person("Typo", in: library) == nil)

        try SpeakerEditing.name(.voice("B"), "Bogdan", in: folder, library: library)
        var saved = VoiceLibrary.load(from: library)
        saved.addAlias("Bogdan Pop", to: "Bogdan")
        try saved.save(to: library)
        try SpeakerEditing.give(.voice("B"), to: .others, in: folder, library: library)
        #expect(person("Bogdan", in: library)?.prints == [])
        #expect(person("Bogdan", in: library)?.aliases == ["Bogdan Pop"])
    }

    @Test("naming a voice as the same person twice keeps one copy of its print")
    func renameSame() throws {
        let (folder, library) = try recording([])
        defer { try? FileManager.default.removeItem(at: folder) }
        try SpeakerEditing.name(.voice("B"), "Ana", in: folder, library: library)
        try SpeakerEditing.name(.voice("B"), "Ana", in: folder, library: library)
        #expect(person("Ana", in: library)?.prints == [owners])
        /// Still the record that naming made, so giving the voice away removes it.
        try SpeakerEditing.give(.voice("B"), to: .others, in: folder, library: library)
        #expect(person("Ana", in: library) == nil)
    }

    @Test("the call window's name a wrong naming filed as an alias is taken back with the print")
    func aliasTakenBack() throws {
        let (folder, library) = try recording([.init(name: "Ana", prints: [anasOwn])],
                                              b: voice("B", print: owners, callName: "Doru Chiulan"))
        defer { try? FileManager.default.removeItem(at: folder) }
        try SpeakerEditing.name(.voice("B"), "Ana", in: folder, library: library)
        #expect(person("Ana", in: library)?.aliases == ["Doru Chiulan"])
        try SpeakerEditing.name(.voice("B"), "Doru", in: folder, library: library)
        #expect(person("Ana", in: library)?.aliases == [])
        #expect(person("Ana", in: library)?.prints == [anasOwn])
        #expect(person("Doru", in: library)?.aliases == ["Doru Chiulan"])
    }

    @Test("a voice named before filings were recorded gives back only its exact print")
    func legacyNaming() throws {
        var legacy = voice("B", "Ana", print: owners)
        legacy.namedByOwner = true
        let (folder, library) = try recording([.init(name: "Ana", prints: [anasOwn, owners])], b: legacy)
        defer { try? FileManager.default.removeItem(at: folder) }
        try SpeakerEditing.give(.voice("B"), to: .others, in: folder, library: library)
        #expect(person("Ana", in: library)?.prints == [anasOwn])

        /// Matched by the library rather than named by the owner: nothing is taken back.
        var matched = voice("B", "Ana", print: owners)
        matched.namedByOwner = nil
        let (other, otherLibrary) = try recording([.init(name: "Ana", prints: [anasOwn, owners])], b: matched)
        defer { try? FileManager.default.removeItem(at: other) }
        try SpeakerEditing.give(.voice("B"), to: .others, in: other, library: otherLibrary)
        #expect(person("Ana", in: otherLibrary)?.prints == [anasOwn, owners])
    }

    // MARK: Provenance

    @Test("a named voice's print records the recording it came from, and survives a save")
    func provenance() throws {
        let (folder, library) = try recording([.init(name: "Ana", prints: [anasOwn])])
        defer { try? FileManager.default.removeItem(at: folder) }
        try SpeakerEditing.name(.voice("B"), "Ana", in: folder, library: library)
        let ana = try #require(person("Ana", in: library))
        #expect(ana.origin(ofPrint: 0) == nil)
        let origin = try #require(ana.origin(ofPrint: 1))
        #expect(origin.recording == folder.lastPathComponent)
        #expect(abs(origin.filed.timeIntervalSinceNow) < 60)
    }

    @Test("old files read without origins, and origins are written only once a print has one")
    func originsOnDisk() throws {
        let old = #"{"name":"Ana","prints":[[0,1]],"aliases":[],"isOwner":false}"#
        let person = try JSONDecoder().decode(VoiceLibrary.Person.self, from: Data(old.utf8))
        #expect(person.prints == [[0, 1]] && person.origin(ofPrint: 0) == nil)
        #expect(String(decoding: try JSONEncoder().encode(person), as: UTF8.self).contains("origins") == false)

        let origin = VoiceLibrary.PrintOrigin(recording: "rec-2026-11-03-100800", filed: Date(timeIntervalSince1970: 1_800_000_000))
        let filed = VoiceLibrary.Person(name: "Ana", prints: [[0, 1], [1, 0]], origins: [nil, origin])
        let read = try JSONDecoder().decode(VoiceLibrary.Person.self, from: JSONEncoder().encode(filed))
        #expect(read == filed)
        #expect(read.origin(ofPrint: 1) == origin)
        #expect(origin.recordingStarted == OutputPlan.date(fromFolderName: "rec-2026-11-03-100800"))
        #expect(origin.recordingStarted != nil)
        #expect(VoiceLibrary.PrintOrigin(recording: "renamed by hand").recordingStarted == nil)
    }

    @Test("exports leave origins behind, and imported prints say they were imported")
    func originsAcrossLibraries() throws {
        let origin = VoiceLibrary.PrintOrigin(recording: "rec-2026-11-03-100800")
        let theirs = VoiceLibrary(people: [.init(name: "Ana", prints: [anasOwn, costis], origins: [origin, origin])])
        let file = try theirs.exported()
        #expect(String(decoding: file, as: UTF8.self).contains("rec-2026") == false)
        var mine = VoiceLibrary(people: [.init(name: "Ana", prints: [anasOwn])])
        try mine.merge(file)
        #expect(mine.people[0].prints == [anasOwn, costis])
        #expect(mine.people[0].origin(ofPrint: 0) == nil)
        #expect(mine.people[0].origin(ofPrint: 1)?.recording == nil)
        #expect(mine.people[0].origin(ofPrint: 1) != nil)
    }

    @Test("removing one print takes its origin with it and keeps the person")
    func removePrint() throws {
        let origin = VoiceLibrary.PrintOrigin(recording: "rec-2026-11-03-100800")
        var library = VoiceLibrary(people: [.init(name: "Ana", prints: [anasOwn, owners, costis], aliases: [], origins: [nil, origin])])
        library.removePrint(at: 0, from: "Ana")
        #expect(library.people[0].prints == [owners, costis])
        #expect(library.people[0].origin(ofPrint: 0) == origin)
        #expect(library.people[0].origin(ofPrint: 1) == nil)
        library.removePrint(at: 5, from: "Ana")
        library.removePrint(at: 0, from: "Nobody")
        library.removePrint(at: 0, from: "Ana")
        library.removePrint(at: 0, from: "Ana")
        #expect(library.people.map(\.name) == ["Ana"])
        #expect(library.people[0].prints.isEmpty)
        library.enroll("Ana", anasOwn)
        #expect(library.people[0].prints == [anasOwn] && library.people[0].origin(ofPrint: 0) == nil)
    }
}
