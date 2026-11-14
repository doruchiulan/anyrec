import Testing
@testable import AnyRecBar
@testable import AnyRecKit

@Suite("Transcription mode selection")
struct TranscriptionModeTests {
    @Test("an engine keeps every other setting, and comparison joins only a review")
    func singleEngine() {
        var defaults = TranscriptionOptions()
        defaults.compareEngines = true
        defaults.reviewProvider = .codex
        defaults.identifySpeakers = false
        defaults.comparisonEngines = [.parakeet, .apple]
        let mode = TranscriptionMode.engine(.whisper)
        var options = mode.options(from: defaults)
        #expect(options.engines(preferred: mode.preferredEngine, available: [.parakeet, .whisper]) == [.whisper])
        options.review = true
        #expect(options.engines(preferred: mode.preferredEngine, available: [.parakeet, .whisper]) == [.whisper, .parakeet])
        #expect(options.reviewProvider == .codex && !options.identifySpeakers)
        #expect(options.comparisonEngines == defaults.comparisonEngines)
    }

    @Test("Automatic never uploads, even with OpenAI enabled")
    func automatic() {
        var defaults = TranscriptionOptions()
        defaults.enabledEngines = [.whisper, .openai]
        let mode = TranscriptionMode.engine(.auto)
        let options = mode.options(from: defaults)
        #expect(options.engines(preferred: mode.preferredEngine, available: [.whisper, .openai]) == [.auto])
        #expect(options.engines(preferred: .auto, available: [.openai]).isEmpty)
        #expect(!TranscriptionMode.allCases.contains { $0.name == "Aggregator" })
    }

    @Test("description says what is compared and where audio and text go")
    func description() {
        var options = TranscriptionOptions()
        options.review = true
        options.compareEngines = true
        options.reviewProvider = .claude
        #expect(TranscriptionMode.engine(.parakeet).description(engines: [.parakeet, .whisper, .openai], options: options)
            .contains("Audio is sent to OpenAI"))
        #expect(TranscriptionMode.engine(.parakeet).description(engines: [.parakeet], options: options)
            == "Fast, on-device transcription in 25 languages.")
        #expect(TranscriptionMode.textProcessing(options: options, summary: .claude)
            == "Text goes to Anthropic for review and summary.")
        #expect(TranscriptionMode.textProcessing(options: options, summary: .openai)
            == "Text goes to Anthropic for review. Text goes to OpenAI for a summary.")
        #expect(TranscriptionMode.textProcessing(options: TranscriptionOptions(), summary: nil).isEmpty)
    }
}
