import Foundation
import Testing

@testable import AnyRecKit
@testable import anyrec

@Suite("anyrec speakers --people")
struct PeopleListingTests {
    private let library = VoiceLibrary(people: [
        .init(name: "Ana", prints: [[0, 1], [1, 0]], aliases: ["Ana Pop"],
              origins: [nil, .init(recording: "rec-2026-11-03-100800")]),
        .init(name: "Doru", prints: [[0.9, 0.1]], isOwner: true),
    ])

    @Test("numbers each person's prints and says where each came from")
    func listing() {
        let text = PeopleListing.text(library)
        #expect(text.contains("Ana — 2 voiceprints"))
        #expect(text.contains("  1) earlier"))
        #expect(text.contains("  2) rec-2026-11-03-100800 ("))
        #expect(text.contains("Doru (you) — 1 voiceprint"))
        #expect(PeopleListing.text(VoiceLibrary()).hasPrefix("Nobody is remembered yet"))
    }

    @Test("--remove-print takes a known person, by any of their names, and a print they have")
    func parse() throws {
        #expect(try PeopleListing.parse(["Ana=2", "Ana Pop=1"], in: library).map { "\($0.0)=\($0.1)" } == ["Ana=2", "Ana=1"])
        #expect(throws: (any Error).self) { try PeopleListing.parse(["Ana=3"], in: library) }
        #expect(throws: (any Error).self) { try PeopleListing.parse(["Nobody=1"], in: library) }
        #expect(throws: (any Error).self) { try PeopleListing.parse(["Ana"], in: library) }
    }
}
