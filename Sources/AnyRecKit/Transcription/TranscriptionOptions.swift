import Foundation

/// How a transcript is made beyond the engine: which engines may run, whether voices are
/// told apart, and the optional review — which can compare the transcript against other
/// engines' ("review with a second engine"). Other engines run only for that comparison.
public struct TranscriptionOptions: Codable, Equatable, Sendable {
    public var enabledEngines: Set<TranscriptionEngine> = [.parakeet, .apple, .whisper]
    /// Engines a review may compare the transcript against.
    public var comparisonEngines: Set<TranscriptionEngine> = [.parakeet, .apple, .whisper]
    public var identifySpeakers = true
    /// Review with a second engine: when review is on, also run the comparison engines and
    /// hand the reviewer every transcript. Off, or with review off, only the chosen engine runs.
    public var compareEngines = false
    public var review = false
    public var reviewProvider: SummaryProvider = .claude

    public init() {}

    /// `parallel` and `aggregatorEngines` are what Aggregator, the old transcription mode,
    /// was stored as. Aggregator ran its engines together and kept the first usable result,
    /// or the reviewed one with review on — which is this: the chosen engine plus a
    /// comparison when reviewing.
    private enum CodingKeys: String, CodingKey {
        case enabledEngines, aggregatorEngines, identifySpeakers, parallel, compareEngines, review, reviewProvider
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabledEngines = try values.decode(Set<TranscriptionEngine>.self, forKey: .enabledEngines)
        comparisonEngines = try values.decodeIfPresent(Set<TranscriptionEngine>.self, forKey: .aggregatorEngines)
            ?? enabledEngines
        identifySpeakers = try values.decodeIfPresent(Bool.self, forKey: .identifySpeakers) ?? true
        compareEngines = try values.decodeIfPresent(Bool.self, forKey: .compareEngines)
            ?? values.decodeIfPresent(Bool.self, forKey: .parallel) ?? false
        review = try values.decodeIfPresent(Bool.self, forKey: .review) ?? false
        reviewProvider = try values.decodeIfPresent(SummaryProvider.self, forKey: .reviewProvider) ?? .claude
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabledEngines, forKey: .enabledEngines)
        try values.encode(comparisonEngines, forKey: .aggregatorEngines)
        try values.encode(identifySpeakers, forKey: .identifySpeakers)
        try values.encode(compareEngines, forKey: .compareEngines)
        try values.encode(review, forKey: .review)
        try values.encode(reviewProvider, forKey: .reviewProvider)
    }

    /// Whether this run compares engines at all.
    public var comparing: Bool { review && compareEngines }

    /// The engine `auto` resolves to among the local ones, in its own order. Apple may
    /// still hand over to Whisper for a language it does not cover.
    static func autoEngine(enabled: Set<TranscriptionEngine>) -> TranscriptionEngine? {
        [.parakeet, .apple, .whisper].first { enabled.contains($0) }
    }

    /// What runs: the chosen engine first, then — only when reviewing with a second
    /// engine — the other comparison engines, never the chosen one twice. Empty when the
    /// chosen engine cannot run.
    public func engines(preferred: TranscriptionEngine, available: Set<TranscriptionEngine>) -> [TranscriptionEngine] {
        let enabled = enabledEngines.intersection(available).subtracting([.auto])
        let primary: TranscriptionEngine
        let resolved: TranscriptionEngine?
        if preferred == .auto {
            guard let local = Self.autoEngine(enabled: enabled) else { return [] }
            primary = .auto
            resolved = local
        } else {
            guard enabled.contains(preferred) else { return [] }
            primary = preferred
            resolved = preferred
        }
        guard comparing else { return [primary] }
        let order: [TranscriptionEngine] = [.parakeet, .apple, .whisper, .openai]
        return [primary] + order.filter { enabled.contains($0) && comparisonEngines.contains($0) && $0 != resolved }
    }
}
