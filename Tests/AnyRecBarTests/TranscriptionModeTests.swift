import Testing
@testable import AnyRecBar
@testable import AnyRecKit

@Suite("Transcription mode selection")
struct TranscriptionModeTests {
    @Test("a single engine overrides parallel defaults without changing them")
    func singleEngine() {
        var defaults = TranscriptionOptions()
        defaults.parallel = true
        defaults.review = true
        defaults.reviewProvider = .codex
        defaults.identifySpeakers = false
        defaults.aggregatorEngines = [.parakeet, .apple]
        let mode = TranscriptionMode.engine(.whisper)
        let options = mode.options(from: defaults)
        #expect(options.engines(preferred: mode.preferredEngine(.parakeet),
                                available: [.parakeet, .whisper]) == [.whisper])
        #expect(defaults.parallel)
        #expect(options.review && options.reviewProvider == .codex && !options.identifySpeakers)
        #expect(options.enabledEngines == defaults.enabledEngines)
        #expect(options.aggregatorEngines == defaults.aggregatorEngines)
    }

    @Test("Automatic runs one local engine even with parallel and OpenAI enabled in defaults")
    func automatic() {
        var defaults = TranscriptionOptions()
        defaults.parallel = true
        defaults.enabledEngines = [.whisper, .openai]
        let mode = TranscriptionMode.engine(.auto)
        let options = mode.options(from: defaults)
        #expect(options.engines(preferred: mode.preferredEngine(.openai),
                                available: [.whisper, .openai]) == [.whisper])
        #expect(options.engines(preferred: .auto, available: [.openai]).isEmpty)
    }

    @Test("Aggregator uses selected enabled available engines even when the preferred engine is excluded")
    func aggregator() {
        var defaults = TranscriptionOptions()
        defaults.enabledEngines = [.parakeet, .whisper, .openai]
        defaults.aggregatorEngines = [.parakeet, .apple]
        let mode = TranscriptionMode.aggregator
        let options = mode.options(from: defaults)
        #expect(options.engines(preferred: mode.preferredEngine(.whisper),
                                available: [.apple, .parakeet, .whisper]) == [.parakeet])
        #expect(!defaults.parallel)
    }

    @Test("description includes remote audio and combines review and summary destinations")
    func description() {
        var options = TranscriptionOptions()
        options.review = true
        options.reviewProvider = .claude
        #expect(TranscriptionMode.aggregator.description(engines: [.whisper, .openai], review: true)
            .contains("Audio is sent to OpenAI"))
        #expect(TranscriptionMode.textProcessing(options: options, summary: .claude)
            == "Text goes to Anthropic for review and summary.")
        #expect(TranscriptionMode.textProcessing(options: options, summary: .openai)
            == "Text goes to Anthropic for review. Text goes to OpenAI for a summary.")
        #expect(TranscriptionMode.textProcessing(options: TranscriptionOptions(), summary: nil).isEmpty)
    }
}
