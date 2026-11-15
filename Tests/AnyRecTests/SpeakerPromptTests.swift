import Foundation
import Testing

@testable import AnyRecKit
@testable import anyrec

@Suite("Speaker prompt")
struct SpeakerPromptTests {
    private func setup() -> (RecordingSpeakers, RecordingSpeakers.Row) {
        let library = VoiceLibrary(people: [
            .init(name: "Andi", prints: [[1, 0]], aliases: ["Andrei Lungu"], displayName: "Andrei Lungu"),
            .init(name: "Andreea", prints: [[0, 1]]),
            .init(name: "Ștefan", prints: [[0, 1]]),
        ])
        let voices = RecordingVoices(voices: [.init(letter: "A", print: [1, 0], sample: "Hi", start: 0, end: 5)])
        let speakers = RecordingSpeakers.build(
            lines: [Utterance(start: 0, end: 5, text: "Hi", speaker: .voice("A"))], voices: voices, suggestions: [],
            corrections: [], participants: nil, info: nil, library: library)
        return (speakers, speakers.rows[0])
    }

    @Test("a name exactly one known person answers to is used directly, spelled as the library spells it")
    func uniqueExact() {
        let (speakers, row) = setup()
        #expect(SpeakerPrompt.reply("stefan", for: row, in: speakers)
            == .answer(.init(speaker: .voice("A"), name: "Ștefan", learnCallName: true, person: "Ștefan")))
        #expect(SpeakerPrompt.reply("andi", for: row, in: speakers)
            == .answer(.init(speaker: .voice("A"), name: "Andi", learnCallName: true, person: "Andi")))
    }

    @Test("text that matches people already named offers them, numbered, before anything is committed")
    func choices() throws {
        let (speakers, row) = setup()
        guard case .choose(let typed, let people) = try #require(SpeakerPrompt.reply("and", for: row, in: speakers)) else {
            Issue.record("expected choices"); return
        }
        #expect(typed == "and")
        #expect(people.map(\.savedName) == ["Andi", "Andreea"])
        #expect(SpeakerPrompt.choices(typed: "lun", speakers.completions(for: row.speaker, typing: "lun"))
            == "    Already named, matching “lun”:\n    1) Andrei Lungu")
        #expect(SpeakerPrompt.choices(typed: "andi", [people[0].withMatch("Andi")]).hasSuffix("1) Andrei Lungu (also Andi)"))

        #expect(SpeakerPrompt.pick("1", typed: typed, from: people, for: row, in: speakers)
            == .answer(.init(speaker: .voice("A"), name: "Andrei Lungu", learnCallName: true, person: "Andi")))
        #expect(SpeakerPrompt.pick("", typed: typed, from: people, for: row, in: speakers)
            == .answer(.init(speaker: .voice("A"), name: "and", learnCallName: true)))
        #expect(SpeakerPrompt.pick("9", typed: typed, from: people, for: row, in: speakers) == .choose(typed: typed, people))
        #expect(SpeakerPrompt.pick("Radu", typed: typed, from: people, for: row, in: speakers)
            == .answer(.init(speaker: .voice("A"), name: "Radu", learnCallName: true)))
    }

    @Test("a voice that is probably you is asked about, offered Me first, and Me gives it to Me")
    func probablyYou() throws {
        let library = VoiceLibrary(people: [.init(name: "Doru", prints: [[1, 0]], isOwner: true)])
        let voices = RecordingVoices(voices: [.init(letter: "A", print: [1, 0], sample: "Hi", start: 0, end: 5, name: "Doru")])
        let speakers = RecordingSpeakers.build(
            lines: [Utterance(start: 0, end: 5, text: "Hi", speaker: .voice("A"))], voices: voices, suggestions: [],
            corrections: [], participants: nil, info: nil, library: library)
        let row = try #require(SpeakerPrompt.questions(speakers).first)
        #expect(SpeakerPrompt.describe(row, in: speakers).contains("probably you: saved as you"))
        #expect(SpeakerPrompt.describe(row, in: speakers).contains("1) Me — your voice"))
        #expect(SpeakerPrompt.reply("1", for: row, in: speakers)
            == .answer(.init(speaker: .voice("A"), name: "Me", learnCallName: false, me: true)))
    }

    @Test("a name nobody answers to is a new name, and an empty reply is none")
    func newName() {
        let (speakers, row) = setup()
        #expect(SpeakerPrompt.reply("Radu", for: row, in: speakers) == .answer(.init(speaker: .voice("A"), name: "Radu", learnCallName: true)))
        #expect(SpeakerPrompt.reply("  ", for: row, in: speakers) == nil)
    }
}

private extension PersonSuggestion {
    func withMatch(_ name: String) -> PersonSuggestion {
        PersonSuggestion(savedName: savedName, shownName: shownName, matched: name, exact: false)
    }
}
