import Foundation

public struct TranscriptionOptions: Codable, Equatable, Sendable {
    public var enabledEngines: Set<TranscriptionEngine> = [.parakeet, .apple, .whisper]
    public var aggregatorEngines: Set<TranscriptionEngine> = [.parakeet, .apple, .whisper]
    public var identifySpeakers = true
    public var parallel = false
    public var review = false
    public var reviewProvider: SummaryProvider = .claude

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabledEngines, aggregatorEngines, identifySpeakers, parallel, review, reviewProvider
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabledEngines = try values.decode(Set<TranscriptionEngine>.self, forKey: .enabledEngines)
        aggregatorEngines = try values.decodeIfPresent(Set<TranscriptionEngine>.self, forKey: .aggregatorEngines)
            ?? enabledEngines
        identifySpeakers = try values.decode(Bool.self, forKey: .identifySpeakers)
        parallel = try values.decode(Bool.self, forKey: .parallel)
        review = try values.decode(Bool.self, forKey: .review)
        reviewProvider = try values.decode(SummaryProvider.self, forKey: .reviewProvider)
    }

    public func engines(preferred: TranscriptionEngine, available: Set<TranscriptionEngine>) -> [TranscriptionEngine] {
        let enabled = enabledEngines.intersection(available).subtracting([.auto])
        let order = [preferred] + [.parakeet, .apple, .whisper, .openai].filter { $0 != preferred }
        if parallel { return order.filter { enabled.contains($0) && aggregatorEngines.contains($0) } }
        if preferred != .auto { return enabled.contains(preferred) ? [preferred] : [] }
        return Array(order.filter { enabled.contains($0) && !$0.isRemote }.prefix(1))
    }
}
