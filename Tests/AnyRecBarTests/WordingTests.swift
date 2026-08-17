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

        #expect(Wording.engine(.apple, with) == "Apple (on-device)")
        #expect(Wording.engine(.apple, without) == "Apple (needs macOS 26)")
        #expect(Wording.engine(nil, with) == "Off")
    }

    /// The terminal offers to install whisper on the spot; a panel has nothing to press
    /// for it, so it names what does.
    @Test("sends setup to the terminal rather than offering a key it cannot take")
    func advisoryPointsAtTheTerminal() {
        #expect(Wording.advisory(.whisperNotSetUp).contains("terminal"))
        #expect(Wording.advisory(.openAIKeyMissing).contains("OPENAI_API_KEY"))
        #expect(!Wording.advisory(.whisperNotSetUp).contains("⏎"))
    }

    @Test("distinguishes a merge nobody asked for from one that could not run")
    func mergeOutcomes() {
        #expect(Wording.merge(.notRequested).contains("as asked"))
        #expect(Wording.merge(.ffmpegMissing).contains("ffmpeg"))
        #expect(Wording.merge(.failed("boom")).contains("boom"))
    }

    @Test("carries the way out when the transcript failed for a fixable reason")
    func failedTranscriptCarriesItsRemedy() {
        let written = Wording.transcript(.failed(reason: "no model", remedy: .installWhisper))

        #expect(written.contains("no model"))
        #expect(written.contains("terminal"))
        #expect(Wording.transcript(.nothingHeard).contains("Nothing was heard"))
    }
}
