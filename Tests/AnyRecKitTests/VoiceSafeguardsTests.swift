import Foundation
import Testing

@testable import AnyRecKit

/// A wrong print names the wrong person on every later call, so the library refuses the
/// ones it can tell are wrong, keeps doubtful ones aside, and finds the ones already in it.
@Suite("Voice library safeguards")
struct VoiceSafeguardsTests {
    private let vladimir: Voiceprint = [1, 0, 0]
    private let owner: Voiceprint = [0, 1, 0]
    private let stranger: Voiceprint = [0, 0, 1]

    // MARK: Admission

    @Test("too little speech, or a voice the call window saw as two people, files nothing")
    func refusedVoices() {
        var library = VoiceLibrary()
        let short = library.consider("Ana", stranger, seconds: 12).admission
        let mixed = library.consider("Ana", stranger, seconds: 60, mixed: true).admission
        #expect(short == .tooShort)
        #expect(mixed == .mixed)
        #expect(library.people.isEmpty)
    }

    @Test("a voice that sounds like someone already known is not filed under another name")
    func soundsLikeSomeoneElse() {
        var library = VoiceLibrary(people: [.init(name: "Vladimir Tikhonov", prints: [vladimir])])
        let result = library.consider("Claudiu", [0.95, 0.1, 0.05], seconds: 60)
        #expect(result.admission == .soundsLike("Vladimir Tikhonov"))
        #expect(result.filing == nil)
        #expect(library.names == ["Vladimir Tikhonov"])
    }

    @Test("a print unlike the person's others waits, is never matched, and joins once another agrees")
    func probation() {
        var library = VoiceLibrary(people: [.init(name: "Doru", prints: [owner], isOwner: true)])
        /// The owner's real library had a second print 0.10 like the first: not the owner.
        let unlike: Voiceprint = [0.1, 0.05, 0.99]
        let first = library.consider("Doru", unlike, seconds: 60).admission
        #expect(first == .waiting)
        #expect(library.people[0].prints == [owner])
        #expect(library.people[0].waiting == [unlike])
        #expect(library.match(unlike) == nil)

        let agreeing: Voiceprint = [0.5, 0.1, 0.86]
        let second = library.consider("Doru", agreeing, seconds: 60).admission
        #expect(second == .confirmed)
        #expect(library.people[0].prints == [owner, unlike, agreeing])
        #expect(library.people[0].waiting.isEmpty)
    }

    @Test("a print like the person's others joins them at once")
    func likeTheRest() {
        var library = VoiceLibrary(people: [.init(name: "Doru", prints: [owner])])
        let admission = library.consider("Doru", [0.5, 0.85, 0.1], seconds: 60).admission
        #expect(admission == .filed)
        #expect(library.people[0].prints.count == 2)
    }

    // MARK: Matching

    @Test("two people about as close name nobody")
    func margin() {
        let library = VoiceLibrary(people: [.init(name: "Vladimir", prints: [vladimir]), .init(name: "Doru", prints: [owner])])
        /// The 12:31 call: 0.68 to Vladimir, 0.68 to the owner.
        #expect(library.match([0.7, 0.69, 0.1]) == nil)
        #expect(library.match([0.9, 0.3, 0.1])?.name == "Vladimir")
    }

    // MARK: Self-repair

    @Test("a voice the library matched to someone, named as someone else, sends that match's print to probation")
    func demote() {
        var library = VoiceLibrary(people: [.init(name: "Vladimir", prints: [vladimir, [0.7, 0, 0.7]])])
        let moved = library.demote(nearestTo: [0.98, 0.1, 0], in: "Vladimir")
        #expect(moved)
        #expect(library.people[0].prints == [[0.7, 0, 0.7]])
        #expect(library.people[0].waiting == [vladimir])
        let movedAgain = library.demote(nearestTo: owner, in: "Vladimir")
        #expect(!movedAgain)
    }

    @Test("renaming a voice the library recognised demotes the print that recognised it")
    func renameRepairs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-safeguard-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = folder.appendingPathComponent("library")
        try VoiceLibrary(people: [.init(name: "Vladimir", prints: [vladimir, [0.2, 0, 0.98]])]).save(to: library)
        var a = RecordingVoices.Voice(letter: "A", print: [0.97, 0.2, 0], sample: "Hi", start: 0, end: 40, name: "Vladimir")
        a.identityEvidence = SpeakerIdentityEvidence(callNames: [], voiceprintName: "Vladimir", conflict: false)
        try TranscriptStore.publish(
            Transcript(utterances: [Utterance(start: 0, end: 40, text: "Hi", speaker: .voice("A"))], language: "en", engine: "parakeet"),
            voices: RecordingVoices(voices: [a]), in: folder)

        try SpeakerEditing.name(.voice("A"), "Claudiu", in: folder, library: library)
        let saved = VoiceLibrary.load(from: library)
        let vlad = try #require(saved.people.first { $0.name == "Vladimir" })
        #expect(vlad.prints == [[0.2, 0, 0.98]])
        #expect(vlad.waiting == [vladimir])
        /// With Vladimir's matching print set aside, the voice no longer sounds like him.
        #expect(saved.people.first { $0.name == "Claudiu" }?.prints == [[0.97, 0.2, 0]])
        #expect(RecordingVoices.read(in: folder)?.voices[0].kept == .filed)
    }

    // MARK: Health

    @Test("two records of one person, and a print unlike its person's others, are issues until answered")
    func issues() {
        var library = VoiceLibrary(people: [
            .init(name: "Vladimir Tikhonov", prints: [vladimir]),
            .init(name: "Vova", prints: [[0.95, 0.1, 0.1]]),
            .init(name: "Doru", prints: [owner, [0.05, 0.1, 0.99]], isOwner: true),
        ])
        let found = library.issues
        #expect(found.contains { if case .samePerson(let a, let b, _) = $0 { Set([a, b]) == ["Vladimir Tikhonov", "Vova"] } else { false } })
        #expect(found.contains(.unlike(person: "Doru", print: 0)))
        #expect(found.contains(.unlike(person: "Doru", print: 1)))

        library.markDifferent("Vova", "Vladimir Tikhonov")
        #expect(!library.issues.contains { if case .samePerson = $0 { true } else { false } })
    }

    @Test("merging a duplicate keeps its prints, its names as nicknames, and the owner flag")
    func merge() {
        var library = VoiceLibrary(people: [
            .init(name: "Vladimir Tikhonov", prints: [vladimir]),
            .init(name: "Vova", prints: [[0.7, 0.7, 0.1]], aliases: ["Vovochka"]),
        ])
        library.mergePerson("Vova", into: "Vladimir Tikhonov")
        #expect(library.names == ["Vladimir Tikhonov"])
        #expect(library.people[0].prints == [vladimir, [0.7, 0.7, 0.1]])
        #expect(library.people[0].aliases == ["Vova", "Vovochka"])
        #expect(library.person(answering: "Vova")?.name == "Vladimir Tikhonov")
    }

    // MARK: On disk

    @Test("waiting prints and \"not the same\" answers are kept on disk, never exported, and old files read without them")
    func onDisk() throws {
        /// In the order the library reads them back: by name.
        var library = VoiceLibrary(people: [.init(name: "Ana", prints: [stranger]), .init(name: "Doru", prints: [owner])])
        library.consider("Doru", [0.05, 0.1, 0.99], seconds: 60)
        library.markDifferent("Doru", "Ana")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-safeguard-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try library.save(to: folder)
        #expect(VoiceLibrary.load(from: folder) == library)

        let exported = try JSONDecoder().decode([VoiceLibrary.Person].self, from: library.exported())
        #expect(exported.allSatisfy { $0.waiting.isEmpty && $0.notSameAs.isEmpty })

        let old = #"{"name":"Ana","prints":[[0,1]],"aliases":[],"isOwner":false}"#
        let person = try JSONDecoder().decode(VoiceLibrary.Person.self, from: Data(old.utf8))
        #expect(person.waiting.isEmpty && person.notSameAs.isEmpty)
    }
}

/// A person keeps a few strong, varied prints rather than one per call forever.
@Suite("Voice library curation")
struct VoiceCurationTests {
    /// One person's prints in different conditions: a shared part plus one condition of
    /// their own, 0.61 alike to each other. A print mixing two conditions is 0.89 like each
    /// of them: redundant, but not a near-copy (`duplicatePrint`).
    private func print(_ conditions: Int...) -> Voiceprint {
        var vector = [Float](repeating: 1, count: 8)
        for condition in conditions { vector[condition] += 3 / Float(conditions.count).squareRoot() }
        let norm = vector.map { $0 * $0 }.reduce(0, +).squareRoot()
        return vector.map { $0 / norm }
    }

    private func origin(_ seconds: TimeInterval) -> VoiceLibrary.PrintOrigin { .init(recording: "rec", seconds: seconds) }

    @Test("a near-copy of a print is not added, unless it was made from more speech, when it takes its place")
    func duplicates() {
        let nearCopy: Voiceprint = print(0).enumerated().map { $0.offset == 7 ? $0.element + 0.05 : $0.element }
        var person = VoiceLibrary.Person(name: "Ana", prints: [print(0)], origins: [origin(40)])
        #expect(person.admit(nearCopy, origin: origin(30)) == .duplicate)
        #expect(person.prints == [print(0)])
        #expect(person.admit(nearCopy, origin: origin(90)) == .replaced)
        #expect(person.prints == [nearCopy])
        #expect(person.retired == [print(0)])
    }

    @Test("past the cap the most redundant print is set aside, never the best")
    func cap() {
        var person = VoiceLibrary.Person(name: "Ana", prints: [], origins: [])
        /// Six varied conditions, the first made from the most speech.
        for condition in 0..<6 {
            person.admit(print(condition), origin: origin(condition == 0 ? 120 : 40))
        }
        #expect(person.prints.count == VoiceLibrary.maximumPrints)
        /// A seventh, close to two others but not a near-copy of either.
        let added = person.admit(print(0, 1), origin: origin(40))
        #expect(added == .added)
        #expect(person.prints.count == VoiceLibrary.maximumPrints)
        #expect(person.prints.contains(print(0)))
        #expect(person.retired.count == 1)
        #expect(person.retired[0] != print(0))
    }

    @Test("a set-aside print can be brought back, and stays")
    func bringBack() throws {
        var library = VoiceLibrary(people: [.init(name: "Ana", prints: [], origins: [])])
        for condition in 0..<7 { library.consider("Ana", print(condition), origin: origin(40), seconds: 40) }
        let retired = library.people[0].retired
        try #require(retired.count == 1)
        library.bringBack(retired: 0, of: "Ana")
        #expect(library.people[0].prints.contains(retired[0]))
        #expect(library.people[0].prints.count == VoiceLibrary.maximumPrints)
        #expect(library.people[0].retired.count == 1)
    }

    @Test("a print made from more speech that agrees with the rest scores higher")
    func quality() {
        let person = VoiceLibrary.Person(name: "Ana", prints: [print(0), print(1)], origins: [origin(120), origin(25)])
        #expect(person.quality(ofPrint: 0) > person.quality(ofPrint: 1))
    }
}
