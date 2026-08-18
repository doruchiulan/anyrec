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

        #expect(Wording.engine(.apple, with) == "Apple (on device, English only)")
        #expect(Wording.engine(.apple, without) == "Apple (needs macOS 26)")
        #expect(Wording.engine(.whisper, with) == "Whisper (on device)")
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
    @Test("says what pressing install will fetch")
    func installNamesItsDownload() {
        let model = WhisperSetup.pending().filter { $0.bytes > 0 }
        let installs: [WhisperSetup.Step] = [.install(formula: "ffmpeg", binary: "ffmpeg")]

        #expect(Wording.install(installs) == "Install")
        if !model.isEmpty { #expect(Wording.install(model).contains("downloads")) }
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
        let written = Wording.transcript(.failed(reason: "no model", remedy: .installWhisper))

        #expect(written.contains("no model"))
        #expect(written.contains("Settings"))
        #expect(Wording.transcript(.nothingHeard).contains("Nothing was heard"))
    }
}
