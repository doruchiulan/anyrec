import AnyRecKit
import Testing

@testable import anyrec

@Suite("Settings")
struct SettingsTests {
    /// Apple is the engine that can be installed, selected, and still have no model
    /// for the call, so the row says how many languages it has before the call starts.
    @Test("counts the languages Apple can actually transcribe")
    func appleLabelCountsLanguages() {
        var settings = Settings(outputRoot: "~/Desktop")
        settings.transcribe = .apple
        settings.appleLanguages = ["en", "fr", "de"]

        #expect(settings.transcribeLabel == "On — Apple, on-device, 3 languages")
    }

    @Test("says why Apple is unavailable rather than offering nought languages")
    func appleLabelWithoutTheEngine() {
        var settings = Settings(outputRoot: "~/Desktop")
        settings.transcribe = .apple

        #expect(settings.transcribeLabel == "On — Apple, which needs macOS 26")
    }

    @Test("names the languages rather than listing their codes")
    func describesLanguages() {
        let described = AppleSpeech.describe(["fr", "en"])

        #expect(described.split(separator: ", ").count == 2)
        #expect(described != "en, fr")
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
