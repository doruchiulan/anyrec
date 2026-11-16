import Foundation
import Testing

@testable import AnyRecKit

@Suite("The call sheet the wording review reads")
struct CallSheetTests {
    private let transcript = Transcript(utterances: [
        Utterance(start: 0, end: 2, text: "activezi la autoricord", speaker: .me),
        Utterance(start: 2, end: 4, text: "și la riviu", speaker: .others),
    ], language: "ro", engine: "parakeet")

    @Test("the topic pass adds a topic and terms after the owner's own vocabulary")
    func topic() async {
        let sheet = CallSheet(title: "Costin - Slack", app: "Slack", date: "2026-11-16", language: "ro",
                              participants: ["Doru Chiulan"], topic: nil, terms: ["AnyRec"])
        let read = await sheet.withTopic(transcript, using: .claude) { instructions, input, _ in
            #expect(instructions == CallSheet.topicInstructions)
            #expect(input.contains("autoricord") && input.contains("Doru Chiulan"))
            return #"Here: {"topic":" Setting up a recorder. ","terms":["auto-record","anyrec","review"]}"#
        }
        #expect(read.topic == "Setting up a recorder.")
        #expect(read.terms == ["AnyRec", "auto-record", "review"], "the owner's spelling wins, each term once")
    }

    @Test("a failed or unreadable topic pass leaves the sheet as it was")
    func failure() async {
        let sheet = CallSheet(title: nil, app: nil, date: nil, language: nil, participants: [], topic: nil, terms: ["x"])
        #expect(await sheet.withTopic(transcript, using: .claude) { _, _, _ in "no JSON here" } == sheet)
        struct Down: Error {}
        #expect(await sheet.withTopic(transcript, using: .claude) { _, _, _ in throw Down() } == sheet)
    }

    @Test("every review section carries the sheet")
    func reviewInput() throws {
        let sheet = CallSheet(title: "t", app: "Slack", date: nil, language: "ro", participants: [], topic: "a call",
                              terms: ["auto-record"])
        let candidates = TranscriptionCandidates(
            primary: TranscriptionService.Transcribed(transcript: transcript, voices: nil), transcripts: [], failures: [])
        let input = try ReviewPrompt.input(candidates, range: 0..<2, sheet: sheet)
        #expect(input.contains("\"callSheet\"") && input.contains("auto-record") && input.contains("a call"))
        #expect(ReviewPrompt.instructions.contains("callSheet"))
    }

    @Test("long calls are sampled evenly, short ones sent whole")
    func sampling() {
        let short = ["a", "b", "c"]
        #expect(CallSheet.sampled(short) == short)
        let long = (0..<2_000).map { _ in String(repeating: "w", count: 100) }
        let sampled = CallSheet.sampled(long)
        #expect(sampled.reduce(0) { $0 + $1.count } <= CallSheet.maximumText)
        #expect(sampled.count > 100, "taken from across the call, not cut off at the start")
    }

    @Test("the date comes from the folder, vocabulary from comma- or line-separated text")
    func parsing() {
        #expect(CallSheet.date(of: URL(filePath: "/x/rec-2026-11-16-095833")) == "2026-11-16")
        #expect(CallSheet.date(of: URL(filePath: "/x/call")) == nil)
        #expect(Vocabulary.words(" AnyRec, auto-record\nGenie,, anyrec ") == ["AnyRec", "auto-record", "Genie"])
        #expect(Vocabulary.text(["a", "b"]) == "a, b")
    }

    @Test("vocabulary survives in saved options, and older options read without it")
    func options() throws {
        var options = TranscriptionOptions()
        options.vocabulary = ["AnyRec"]
        #expect(try JSONDecoder().decode(TranscriptionOptions.self, from: JSONEncoder().encode(options)).vocabulary == ["AnyRec"])
        let older = Data(#"{"enabledEngines":["parakeet"]}"#.utf8)
        #expect(try JSONDecoder().decode(TranscriptionOptions.self, from: older).vocabulary.isEmpty)
    }
}
