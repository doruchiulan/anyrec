import AnyRecKit

/// The engine a transcript is made with. Comparing engines is no longer a mode of its
/// own: it is part of review ("Review with a second engine"), so the chosen engine always
/// writes the transcript and the others only inform the reviewer.
enum TranscriptionMode: Hashable, CaseIterable {
    case engine(TranscriptionEngine)

    static let allCases: [Self] = [.engine(.auto), .engine(.parakeet), .engine(.apple), .engine(.whisper), .engine(.openai)]

    var name: String {
        switch self {
        case .engine(let engine): Wording.engineName(engine)
        }
    }

    var preferredEngine: TranscriptionEngine {
        switch self {
        case .engine(let engine): engine
        }
    }

    func options(from defaults: TranscriptionOptions) -> TranscriptionOptions { defaults }

    func description(engines: [TranscriptionEngine], options: TranscriptionOptions) -> String {
        let base: String
        switch preferredEngine {
        case .auto: base = "Chooses one available on-device engine."
        case .parakeet: base = "Fast, on-device transcription in 25 languages."
        case .apple: base = "On-device transcription using Apple’s speech recognition."
        case .whisper: base = "Multilingual transcription on this Mac."
        case .openai: base = "Cloud transcription with speaker labels. Audio is sent to OpenAI."
        }
        let others = engines.dropFirst()
        guard options.comparing, !others.isEmpty else { return base }
        let names = others.map(Wording.engineName).joined(separator: ", ")
        let remote = others.contains(.openai) && preferredEngine != .openai ? " Audio is sent to OpenAI for the comparison." : ""
        return base + " Review also compares it with \(names)." + remote
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
