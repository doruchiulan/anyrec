import AnyRecKit
import Testing

@testable import anyrec

@Suite("Configuration rows")
struct ConfigurationRowsTests {
    /// Apple is the engine that can be installed, selected, and still have no model
    /// for the call, so the row says how many languages it has before the call starts.
    @Test("counts the languages Apple can actually transcribe")
    func appleLabelCountsLanguages() {
        var configuration = RecordingConfiguration(outputRoot: "~/Desktop")
        configuration.transcribe = .apple

        let label = configuration.transcribeLabel(Readiness(appleLanguages: ["en", "fr", "de"]))

        #expect(label == "On — Apple, on-device, 3 languages")
    }

    @Test("says why Apple is unavailable rather than offering nought languages")
    func appleLabelWithoutTheEngine() {
        var configuration = RecordingConfiguration(outputRoot: "~/Desktop")
        configuration.transcribe = .apple

        let label = configuration.transcribeLabel(Readiness(appleLanguages: []))

        #expect(label == "On — Apple, which needs macOS 26")
    }

    /// Cycling wraps in both directions, so ← from the top lands on the last engine
    /// rather than on nothing.
    @Test("cycles the engines round in both directions")
    func cyclesTranscribe() {
        var configuration = RecordingConfiguration(outputRoot: "~/Desktop")

        configuration.cycleTranscribe(by: -1)
        #expect(configuration.transcribe == RecordingConfiguration.transcribeChoices.last!)

        configuration.cycleTranscribe(by: 1)
        #expect(configuration.transcribe == nil)
    }
}

@Suite("EngineSetup")
struct EngineSetupTests {
    /// The language list is a sentence on a page that clips rather than wraps.
    @Test("breaks a long line at a space, and never mid-word")
    func wraps() {
        let wrapped = EngineSetup.wrapped("Cantonese, Chinese, English, French, German", to: 20)

        #expect(wrapped == ["Cantonese, Chinese,", "English, French,", "German"])
    }

    @Test("leaves a line that fits alone")
    func doesNotWrapShortText() {
        #expect(EngineSetup.wrapped("English, French", to: 40) == ["English, French"])
    }
}
