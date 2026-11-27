import Foundation
import Testing

@testable import AnyRecKit

@Suite("Lines nobody claimed")
struct UnclaimedLineReviewTests {
    private let lines = [
        Utterance(start: 0, end: 3, text: "But I can add", speaker: .voice("A")),
        Utterance(start: 3, end: 3.4, text: "it.", speaker: .others),
        Utterance(start: 4, end: 8, text: "Sam, did you join?", speaker: .voice("A")),
        Utterance(start: 8, end: 9, text: "Yep, I'm here.", speaker: .others),
        Utterance(start: 9, end: 9.3, text: "Yeah.", speaker: .others),
        Utterance(start: 10, end: 14, text: "Good, let's start.", speaker: .voice("A")),
    ]

    private var voices: RecordingVoices {
        RecordingVoices(voices: [.init(letter: "A", print: [], sample: "", start: 0, end: 3, name: "Alex Morgan")])
    }

    private var window: CallParticipants {
        CallParticipants(observations: (0...14).map { second in
            .init(at: Double(second), source: "com.microsoft.teams2:1:1", participants: ["Alex Morgan", "Sam Rivera"],
                  speaking: second >= 8 && second < 10 ? ["Sam Rivera"] : ["Alex Morgan"])
        })
    }

    private let reply = """
    Here you go: {"lines":[
      {"id":1,"name":"Alex Morgan","sure":true,"reason":"Finishes his sentence."},
      {"id":3,"name":"Sam Rivera","sure":false,"reason":"Answers the question put to Sam."},
      {"id":0,"name":"Alex Morgan","sure":true,"reason":"Already his."},
      {"id":4,"name":"Somebody Else","sure":true,"reason":"Not in the call."},
      {"id":1,"name":"Sam Rivera","sure":true,"reason":"A second answer for the same line."}
    ]}
    """

    @Test("each line goes with the lines around it, who the call showed talking, and everyone it may name")
    func input() throws {
        let people = UnclaimedLineReview.people(in: lines, voices: voices, participants: window)
        #expect(people.names == ["Alex Morgan", "Sam Rivera"])
        #expect(people.speakers["Alex Morgan"] == .voice("A") && people.speakers["Sam Rivera"] == .named("Sam Rivera"))
        let json = try UnclaimedLineReview.input([3], lines: lines, voices: voices, spans: window.spans, people: people.names)
        #expect(json.contains("Sam, did you join?") && json.contains("Good, let's start.") && json.contains(#""speaker":"?""#))
        #expect(json.contains(#""names":"Sam Rivera""#))
    }

    @Test("an answer counts only for a line asked about, still unclaimed, with a name from the call; sure and likely kept apart")
    func parse() throws {
        let people = UnclaimedLineReview.people(in: lines, voices: voices, participants: window)
        let placement = try #require(UnclaimedLineReview.parse(reply, batch: [1, 3, 4], lines: lines, people: people))
        #expect(placement.sure.map(\.line) == [1] && placement.sure[0].to == .voice("A") && placement.sure[0].sure == true)
        #expect(placement.likely.map(\.line) == [3] && placement.likely[0].to == .named("Sam Rivera") && placement.likely[0].sure == false)
        #expect(UnclaimedLineReview.parse("I can't tell.", batch: [1], lines: lines, people: people) == nil)
    }

    @Test("asking keeps every answer as a proposal and assigns nothing; Assign All gives them their speakers in one change")
    func roundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-unclaimed-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try TranscriptStore.publish(Transcript(utterances: lines, language: "en", engine: "parakeet"), voices: voices, in: directory)
        try window.write(in: directory)

        let outcome = try await UnclaimedLineReview.suggest(in: directory, using: .claude, progress: { _ in }) { instructions, _, _ in
            #expect(instructions == UnclaimedLineReview.instructions)
            return self.reply
        }
        #expect(outcome.asked == 3 && outcome.placement.sure.count == 1 && outcome.placement.likely.count == 1)
        var current = try #require(RecordingTranscript.read(in: directory))
        #expect(current.transcript.utterances.map(\.speaker) == lines.map(\.speaker))
        #expect(current.pendingSpeakerChanges.map(\.line) == [1, 3])

        /// "Yeah." was asked about and left unanswered: it is not asked about again, and the
        /// People panel no longer offers to ask.
        let again = try await UnclaimedLineReview.suggest(in: directory, using: .claude, progress: { _ in }) { _, _, _ in
            Issue.record("asked again")
            return #"{"lines":[]}"#
        }
        #expect(again.asked == 0)
        let speakers = try #require(RecordingSpeakers.read(in: directory, library: VoiceLibrary(), participants: window))
        #expect(speakers.askedAboutUnclaimed == [1, 3, 4])
        /// A call of two: the one other person can still be given every leftover line.

        try TranscriptSpeakerReview.apply(current.pendingSpeakerChanges, in: directory)
        current = try #require(RecordingTranscript.read(in: directory))
        #expect(current.transcript.utterances.map(\.speaker) == [.voice("A"), .voice("A"), .voice("A"), .named("Sam Rivera"), .others, .voice("A")])
        #expect(current.pendingSpeakerChanges.isEmpty)
    }

    @Test("on a call of several, leftover lines are never offered to one person: only asking about the ones not yet asked")
    func bitsOnACallOfSeveral() {
        let several = lines + [Utterance(start: 15, end: 18, text: "Hi all", speaker: .named("Sam Rivera"))]
        var speakers = RecordingSpeakers.build(lines: several, voices: voices, suggestions: [], corrections: [],
                                               participants: nil, info: nil, library: VoiceLibrary())
        let bits = { () -> (lines: [Int], onlyOther: Speaker?)? in
            guard case .unnamedBits(let lines, _, let onlyOther)? = speakers.questions.first(where: { $0.id == "bits" })?.kind else { return nil }
            return (lines, onlyOther)
        }
        #expect(bits()?.lines == [1, 3, 4] && bits()?.onlyOther == nil)
        speakers.askedAboutUnclaimed = [1, 3]
        #expect(bits()?.lines == [4])
        speakers.askedAboutUnclaimed = [1, 3, 4]
        #expect(bits() == nil)
    }

    @Test("once the model has been asked about all of them, the ones the call window showed someone on are asked line by line with that guess")
    func leftoversWithTheWindowsGuess() {
        let several = lines + [Utterance(start: 15, end: 18, text: "Hi all", speaker: .named("Sam Rivera"))]
        var speakers = RecordingSpeakers.build(lines: several, voices: voices, suggestions: [], corrections: [],
                                               participants: window, info: nil, library: VoiceLibrary())
        #expect(!speakers.questions.contains { $0.id == "lines-others" })
        speakers.askedAboutUnclaimed = [1, 3, 4]
        #expect(speakers.questions.first { $0.id == "lines-others" }?.kind
            == .eachLine(.others, lines: [1, 3], guesses: [1: "Alex Morgan", 3: "Sam Rivera"], severalPeople: false))
    }

    @Test("the People panel asks about the sure ones together, the likely ones one by one, and the review's own apart")
    func questions() {
        var sure = SpeakerCorrection(line: 1, from: .others, to: .voice("A"), reason: "r", quote: "it.", evidenceLine: 1)
        sure.sure = true
        var likely = SpeakerCorrection(line: 3, from: .others, to: .named("Sam Rivera"), reason: "r", quote: "Yep", evidenceLine: 3)
        likely.sure = false
        let review = SpeakerCorrection(line: 5, from: .voice("A"), to: .others, reason: "r", quote: "Good", evidenceLine: 5)
        let speakers = RecordingSpeakers.build(lines: lines, voices: voices, suggestions: [], corrections: [sure, likely, review],
                                               participants: nil, info: nil, library: VoiceLibrary())
        let fixes = speakers.questions.filter { $0.id.hasPrefix("fixes") }
        #expect(fixes.map(\.id) == ["fixes-sure", "fixes-likely", "fixes"])
        #expect(fixes.map(\.kind) == [.fixes([sure]), .fixes([likely]), .fixes([review])])
    }
}
