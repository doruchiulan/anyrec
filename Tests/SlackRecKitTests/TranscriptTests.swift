import Foundation
import Testing

@testable import SlackRecKit

@Suite("Transcript")
struct TranscriptTests {
    private func transcript(_ utterances: [Utterance]) -> Transcript {
        Transcript(utterances: utterances, language: "en", engine: "test")
    }

    private func line(_ start: TimeInterval, _ end: TimeInterval, _ text: String, _ who: Speaker)
        -> Utterance
    {
        Utterance(start: start, end: end, text: text, speaker: who)
    }

    @Test("interleaves the two tracks by time")
    func interleaves() {
        let result = transcript([
            line(10, 12, "second", .others),
            line(0, 5, "first", .me),
            line(13, 15, "third", .me),
        ])
        #expect(result.utterances.map(\.text) == ["first", "second", "third"])
    }

    @Test("folds consecutive lines from one speaker into a turn")
    func foldsTurns() {
        let result = transcript([
            line(0, 2, "Hi everyone.", .me),
            line(2, 4, "Thanks for joining.", .me),
            line(5, 7, "Sounds good.", .others),
        ])
        #expect(result.turns.count == 2)
        #expect(result.turns[0].text == "Hi everyone. Thanks for joining.")
        #expect(result.turns[0].start == 0)
        #expect(result.turns[1].speaker == .others)
    }

    @Test("drops empty utterances")
    func dropsEmpty() {
        #expect(transcript([line(0, 1, "   ", .me), line(1, 2, "kept", .me)]).utterances.count == 1)
    }

    @Test("duration is the last thing said")
    func duration() {
        #expect(transcript([line(0, 5, "a", .me), line(2, 19.5, "b", .others)]).duration == 19.5)
    }

    @Test("plain text labels every turn with its speaker")
    func plainText() {
        let text = transcript([line(0, 2, "a", .me), line(65, 70, "b", .others)]).plainText
        #expect(text == "[00:00] Me: a\n\n[01:05] Call: b")
    }

    @Test("markdown carries the engine and language")
    func markdown() {
        let text = transcript([line(0, 2, "a", .me)]).markdown(title: "call")
        #expect(text.hasPrefix("# call\n"))
        #expect(text.contains("English · transcribed by test"))
        #expect(text.contains("**[00:00] Me:** a"))
    }

    @Test("markdown puts a note above the lines it casts doubt on")
    func note() {
        let text = Transcript(
            utterances: [line(0, 2, "a", .me)], language: "en", engine: "test",
            notes: ["Something the reader needs first."]
        ).markdown(title: "call")

        #expect(text.contains("\n> Something the reader needs first."))
        #expect(text.range(of: "> Something")!.lowerBound < text.range(of: "**[00:00]")!.lowerBound)
    }

    @Test("names a diarised voice rather than lumping it in with the call")
    func voices() {
        let text = transcript([
            line(0, 2, "a", .me), line(2, 4, "b", .voice("A")), line(4, 6, "c", .voice("B")),
        ]).plainText

        #expect(text == "[00:00] Me: a\n\n[00:02] Speaker A: b\n\n[00:04] Speaker B: c")
    }

    @Test("leaves the language out of the header rather than claiming one it never got")
    func undetectedLanguage() {
        let transcript = Transcript(
            utterances: [line(0, 2, "a", .me)], language: nil, engine: "test")

        #expect(transcript.languageName == nil)
        #expect(transcript.markdown(title: "call").contains("00:02 · transcribed by test"))
    }

    @Test("srt numbers cues from one and stamps them to the millisecond")
    func srt() {
        let text = transcript([line(0, 1.5, "a", .me), line(3_661.25, 3_662, "b", .others)]).srt
        #expect(text.contains("1\n00:00:00,000 --> 00:00:01,500\nMe: a"))
        #expect(text.contains("2\n01:01:01,250 --> 01:01:02,000\nCall: b"))
    }

    @Test("clock drops the hour until there is one")
    func clock() {
        #expect(Transcript.clock(9) == "00:09")
        #expect(Transcript.clock(605) == "10:05")
        #expect(Transcript.clock(3_661) == "1:01:01")
    }
}
