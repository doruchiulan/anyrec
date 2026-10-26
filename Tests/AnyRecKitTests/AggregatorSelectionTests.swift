import Foundation
import Testing
@testable import AnyRecKit

@Suite("Independent Aggregator membership")
struct AggregatorSelectionTests {
    @Test("excluding an engine from Aggregator leaves it available individually and to Automatic")
    func independentSelection() {
        var options = TranscriptionOptions()
        options.aggregatorEngines = [.parakeet, .apple]
        #expect(options.engines(preferred: .whisper, available: [.whisper]) == [.whisper])
        #expect(options.engines(preferred: .auto, available: [.whisper]) == [.whisper])
        options.parallel = true
        #expect(options.engines(preferred: .whisper, available: [.whisper, .parakeet, .apple]) == [.parakeet, .apple])
        #expect(options.engines(preferred: .whisper, available: [.whisper]).isEmpty)
    }

    @Test("membership cannot bypass global disable or availability, and an empty selection has no fallback")
    func eligibility() {
        var options = TranscriptionOptions()
        options.parallel = true
        options.aggregatorEngines = [.parakeet, .whisper, .openai]
        options.enabledEngines = [.apple, .whisper]
        #expect(options.engines(preferred: .openai, available: [.apple, .parakeet, .whisper, .openai]) == [.whisper])
        #expect(options.engines(preferred: .auto, available: [.apple, .parakeet]).isEmpty)
        options.aggregatorEngines = []
        #expect(options.engines(preferred: .whisper, available: [.whisper]).isEmpty)
    }

    @Test("enabling OpenAI alone does not opt it into Aggregator")
    func remoteOptIn() {
        var options = TranscriptionOptions()
        options.parallel = true
        options.enabledEngines.insert(.openai)
        #expect(options.engines(preferred: .openai, available: [.whisper, .openai]) == [.whisper])
        options.aggregatorEngines.insert(.openai)
        #expect(options.engines(preferred: .openai, available: [.whisper, .openai]) == [.openai, .whisper])
    }

    @Test("legacy settings preserve participants and all other options")
    func migration() throws {
        let legacy = Data(#"{"enabledEngines":["whisper","openai"],"identifySpeakers":false,"parallel":true,"review":true,"reviewProvider":"codex"}"#.utf8)
        let options = try JSONDecoder().decode(TranscriptionOptions.self, from: legacy)
        #expect(options.aggregatorEngines == [.whisper, .openai])
        #expect(options.enabledEngines == [.whisper, .openai])
        #expect(!options.identifySpeakers && options.parallel && options.review && options.reviewProvider == .codex)
        #expect(options.engines(preferred: .auto, available: [.whisper, .openai]) == [.whisper, .openai])
    }

    @Test("separate selections survive persistence, including an intentionally empty Aggregator")
    func persistence() throws {
        for members: Set<TranscriptionEngine> in [[.apple], []] {
            var options = TranscriptionOptions()
            options.aggregatorEngines = members
            let restored = try JSONDecoder().decode(TranscriptionOptions.self, from: JSONEncoder().encode(options))
            #expect(restored == options)
            #expect(restored.aggregatorEngines == members)
        }
    }
}
