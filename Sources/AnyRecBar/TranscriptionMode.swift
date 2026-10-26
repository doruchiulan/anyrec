import AnyRecKit

enum TranscriptionMode: Hashable, CaseIterable {
    case engine(TranscriptionEngine)
    case aggregator

    static let allCases: [Self] = [.engine(.auto), .aggregator, .engine(.parakeet),
                                  .engine(.apple), .engine(.whisper), .engine(.openai)]

    var name: String {
        switch self {
        case .engine(let engine): Wording.engineName(engine)
        case .aggregator: "Aggregator"
        }
    }

    func preferredEngine(_ fallback: TranscriptionEngine) -> TranscriptionEngine {
        if case .engine(let engine) = self { return engine }
        return fallback
    }

    func options(from defaults: TranscriptionOptions) -> TranscriptionOptions {
        var options = defaults
        options.parallel = self == .aggregator
        return options
    }

    func description(engines: [TranscriptionEngine], review: Bool) -> String {
        switch self {
        case .engine(.auto):
            return "Chooses one available on-device engine."
        case .engine(.parakeet):
            return "Fast, on-device transcription in 25 languages."
        case .engine(.apple):
            return "On-device transcription using Apple’s speech recognition."
        case .engine(.whisper):
            return "Multilingual transcription on this Mac."
        case .engine(.openai):
            return "Cloud transcription with speaker labels. Audio is sent to OpenAI."
        case .aggregator:
            guard !engines.isEmpty else { return "Select an available engine in Settings › Transcription › Aggregator engines." }
            let names = engines.map(Wording.engineName).joined(separator: ", ")
            let run = engines.count > 1 ? "Runs \(names) together." : "Runs \(names), the only selected engine currently available."
            let location = engines.contains(.openai) ? " Audio is sent to OpenAI." : " Audio stays on this Mac."
            let primary = !review ? " Uses \(engines.first.map(Wording.engineName) ?? "the first engine") for the final transcript." : ""
            return run + location + primary
        }
    }

    static func textProcessing(options: TranscriptionOptions, summary: SummaryProvider?) -> String {
        if options.review, let summary, summary.company == options.reviewProvider.company {
            return "Text goes to \(summary.company) for review and summary."
        }
        var steps: [String] = []
        if options.review { steps.append("Text goes to \(options.reviewProvider.company) for review.") }
        if let summary { steps.append("Text goes to \(summary.company) for a summary.") }
        return steps.joined(separator: " ")
    }
}
