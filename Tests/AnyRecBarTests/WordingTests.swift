import Foundation
import Testing

@testable import AnyRecBar
@testable import AnyRecKit

@Suite("Menu bar wording")
struct WordingTests {
    /// A call runs for minutes, not hours, and an hours field that is almost always
    /// "00:" reads as noise — so it only appears once there is one.
    @Test("drops the hours field until there are hours")
    func clockGrowsWithTheRecording() {
        #expect(Wording.clock(0) == "00:00")
        #expect(Wording.clock(75) == "01:15")
        #expect(Wording.clock(3_600) == "1:00:00")
        #expect(Wording.clock(7_384) == "2:03:04")
    }

    @Test("names the app that took the microphone, and says the button opens the picker")
    func callOffer() {
        let offer = Wording.callOffer(CallApp(bundleID: "us.zoom.xos", name: "Zoom"))

        #expect(offer.title == "Zoom is on a call")
        #expect(offer.body.contains("picker"))
    }

    @Test("names the default microphone as the default")
    func namesTheDefault() {
        let device = AudioInputDevice(id: "1", name: "MacBook Pro Microphone", isDefault: true)

        #expect(Wording.microphone(device) == "MacBook Pro Microphone (default)")
        #expect(Wording.microphone(nil) == "Off")
    }

    /// Every engine is listed at once, so one that cannot run has to say so on its own
    /// row rather than leaving the advisory to explain a greyed-out word.
    @Test("says on the engine's own row when it cannot run")
    func engineSaysWhenItCannotRun() {
        let without = Readiness(appleLanguages: [])
        let with = Readiness(appleLanguages: ["en"])

        #expect(Wording.engine(.apple, with) == "Apple (on device, English only)")
        #expect(Wording.engine(.apple, without) == "Apple (needs macOS 26)")
        let whisper = with.of(.whisper).isReady ? "Whisper (on device)" : "Whisper (not installed)"
        #expect(Wording.engine(.whisper, with) == whisper)
        #expect(Wording.engine(nil, with) == "Off")
    }

    /// The terminal offers to install whisper on the row itself; the panel has no ⏎ and
    /// no row to press it on, so it names the window that does. Naming the terminal would
    /// be advice someone who installed only the app cannot take.
    @Test("sends setup to the window that can do it, not to a terminal")
    func advisoryPointsAtSettings() {
        #expect(Wording.advisory(.whisperNotSetUp).contains("Settings"))
        #expect(Wording.advisory(.openAIKeyMissing).contains("OPENAI_API_KEY"))
        #expect(!Wording.advisory(.whisperNotSetUp).contains("terminal"))
        #expect(!Wording.advisory(.whisperNotSetUp).contains("⏎"))
    }

    /// What a download will cost is on the button, never after it.
    @Test("says what pressing the button will fetch")
    func installNamesItsDownload() {
        #expect(Wording.install([.fetch(WhisperSetup.model)]) == "Download (574 MB)")
        #expect(Wording.install([.fetchFFmpeg, .fetchParakeet]).hasPrefix("Download ("))
    }

    @Test("separates a key OpenAI refused from one it merely could not check")
    func keyOutcomes() {
        #expect(Wording.wasRefused(.rejected("bad key")))
        #expect(Wording.wasRefused(.notSaved("disk full")))
        #expect(!Wording.wasRefused(.savedUnverified(reason: "offline")))
        #expect(!Wording.wasRefused(.savedButShadowed))
        #expect(Wording.keyOutcome(.savedButShadowed).contains("OPENAI_API_KEY"))
        #expect(Wording.keyOutcome(.rejected("bad key")).contains("bad key"))
    }

    @Test("distinguishes a merge nobody asked for from one that could not run")
    func mergeOutcomes() {
        #expect(Wording.merge(.notRequested).contains("as asked"))
        #expect(Wording.merge(.ffmpegMissing).contains("ffmpeg"))
        #expect(Wording.merge(.failed("boom")).contains("boom"))
    }

    @Test("carries the way out when the transcript failed for a fixable reason")
    func failedTranscriptCarriesItsRemedy() {
        let written = Wording.transcript(.failed(reason: "no model", remedy: .downloadModel(into: URL(fileURLWithPath: "/models"))))

        #expect(written.contains("no model"))
        #expect(written.contains("Settings"))
        #expect(Wording.transcript(.nothingHeard).contains("Nothing was heard"))
    }

    @Test("calls a recording by when it began")
    func titles() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_792_580_000)
        let earlier = now.addingTimeInterval(-3_600)
        let yesterday = now.addingTimeInterval(-86_400)

        #expect(Wording.title(started: earlier, now: now, calendar: calendar).hasPrefix("Today, "))
        #expect(Wording.title(started: yesterday, now: now, calendar: calendar).hasPrefix("Yesterday, "))
        #expect(Wording.group(yesterday, now: now, calendar: calendar) == "Yesterday")
        #expect(Wording.group(now.addingTimeInterval(-4 * 86_400), now: now, calendar: calendar) == "Previous 7 Days")
        #expect(Wording.group(now.addingTimeInterval(-20 * 86_400), now: now, calendar: calendar) == "Previous 30 Days")
    }

    @Test("a short line is its own caption")
    func shortCaption() {
        let line = Utterance(start: 0, end: 4, text: "Sunt bine, mulţumesc.", speaker: .voice("A"))
        #expect(Wording.caption(of: line, at: 2) == "Sunt bine, mulţumesc.")
    }

    @Test("a long line is cut at sentence ends and follows the time across its span")
    func longCaption() {
        let first = String(repeating: "a", count: 50) + "."
        let second = String(repeating: "b", count: 50) + "."
        let line = Utterance(start: 10, end: 20, text: "\(first) \(second)", speaker: .me)

        #expect(Wording.caption(of: line, at: 11) == first)
        #expect(Wording.caption(of: line, at: 19) == second)
    }

    @Test("joins short sentences up to the limit, and cuts a sentence with no breaks at spaces")
    func captionPieces() {
        #expect(Wording.captionPieces("Da. Nu. Poate.", limit: 10) == ["Da. Nu.", "Poate."])
        let words = Array(repeating: "word", count: 30).joined(separator: " ")
        let pieces = Wording.captionPieces(words, limit: 20)
        #expect(pieces.allSatisfy { $0.count <= 20 })
        #expect(pieces.joined(separator: " ") == words)
    }
}
