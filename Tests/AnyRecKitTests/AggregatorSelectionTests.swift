import Foundation
import Testing
@testable import AnyRecKit

@Suite("Review with a second engine")
struct AggregatorSelectionTests {
    @Test("the chosen engine always runs first; comparison engines only join a review")
    func comparisonOnlyWithReview() {
        var options = TranscriptionOptions()
        options.comparisonEngines = [.parakeet, .apple]
        options.compareEngines = true
        let available: Set<TranscriptionEngine> = [.whisper, .parakeet, .apple]
        #expect(options.engines(preferred: .whisper, available: available) == [.whisper])
        options.review = true
        #expect(options.engines(preferred: .whisper, available: available) == [.whisper, .parakeet, .apple])
        #expect(options.engines(preferred: .auto, available: available) == [.auto, .apple])
        options.compareEngines = false
        #expect(options.engines(preferred: .whisper, available: available) == [.whisper])
    }

    @Test("comparison cannot bypass global disable or availability")
    func eligibility() {
        var options = TranscriptionOptions()
        options.review = true
        options.compareEngines = true
        options.comparisonEngines = [.parakeet, .whisper, .openai]
        options.enabledEngines = [.apple, .whisper]
        #expect(options.engines(preferred: .apple, available: [.apple, .parakeet, .whisper, .openai]) == [.apple, .whisper])
        #expect(options.engines(preferred: .openai, available: [.apple, .whisper, .openai]).isEmpty)
        options.comparisonEngines = []
        #expect(options.engines(preferred: .whisper, available: [.whisper]) == [.whisper])
    }

    @Test("enabling OpenAI alone does not opt it into a comparison")
    func remoteOptIn() {
        var options = TranscriptionOptions()
        options.review = true
        options.compareEngines = true
        options.enabledEngines.insert(.openai)
        options.comparisonEngines = [.whisper]
        #expect(options.engines(preferred: .parakeet, available: [.parakeet, .whisper, .openai]) == [.parakeet, .whisper])
        options.comparisonEngines.insert(.openai)
        #expect(options.engines(preferred: .parakeet, available: [.parakeet, .whisper, .openai]) == [.parakeet, .whisper, .openai])
    }

    @Test("Aggregator settings migrate to the same meaning: review compares, without review the first engine alone")
    func migration() throws {
        let reviewed = Data(#"{"enabledEngines":["whisper","openai"],"identifySpeakers":false,"parallel":true,"review":true,"reviewProvider":"codex"}"#.utf8)
        let options = try JSONDecoder().decode(TranscriptionOptions.self, from: reviewed)
        #expect(options.comparisonEngines == [.whisper, .openai])
        #expect(options.enabledEngines == [.whisper, .openai])
        #expect(!options.identifySpeakers && options.compareEngines && options.review && options.reviewProvider == .codex)
        #expect(options.engines(preferred: .auto, available: [.whisper, .openai]) == [.auto, .openai])
        let unreviewed = Data(#"{"enabledEngines":["parakeet","whisper"],"aggregatorEngines":["parakeet","whisper"],"identifySpeakers":true,"parallel":true,"review":false,"reviewProvider":"claude"}"#.utf8)
        let plain = try JSONDecoder().decode(TranscriptionOptions.self, from: unreviewed)
        #expect(plain.engines(preferred: .auto, available: [.parakeet, .whisper]) == [.auto])
        let encoded = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!encoded.contains("parallel") && encoded.contains("compareEngines"))
    }

    @Test("selections survive persistence, including an intentionally empty comparison")
    func persistence() throws {
        for members: Set<TranscriptionEngine> in [[.apple], []] {
            var options = TranscriptionOptions()
            options.comparisonEngines = members
            options.compareEngines = true
            let restored = try JSONDecoder().decode(TranscriptionOptions.self, from: JSONEncoder().encode(options))
            #expect(restored == options)
            #expect(restored.comparisonEngines == members)
        }
    }
}
