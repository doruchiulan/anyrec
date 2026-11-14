import Foundation

/// Who writes a summary, and in what language. Asking for one is asking for the
/// transcript's text to go to that provider; nothing else does.
public struct SummaryRequest: Sendable, Equatable {
    public var provider: SummaryProvider
    /// A language name such as "English"; nil follows the call.
    public var language: String?

    public init(provider: SummaryProvider, language: String? = nil) {
        self.provider = provider
        self.language = language
    }
}

/// How the summary step went, for the interface that asked for it.
public enum SummaryOutcome: Sendable, Equatable {
    case written(URL)
    case failed(String)
}

/// The summary of a recording's current transcript, written beside it and selected with
/// it. One step every interface runs the same way — the app after a transcript or from
/// its Summary card, `anyrec transcribe --summarize`, `anyrec record` and the terminal UI.
/// Unnamed speakers are written by their labels and filled in when shown, so naming a
/// voice later never needs this again; changed words or a changed name make the summary
/// stale, which is said, not silently redone.
public enum SummaryPass {
    public static func write(in directory: URL, request: SummaryRequest) async throws -> URL {
        try await write(in: directory, request: request) {
            try await LLMClient.complete(instructions: $0, text: $1, using: $2)
        }
    }

    static func write(
        in directory: URL, request: SummaryRequest, complete: @escaping TranscriptReviewer.Completion
    ) async throws -> URL {
        guard let current = TranscriptStore.current(in: directory) else {
            throw TranscriptionError.engineFailed(engine: request.provider.rawValue, log: "There is no transcript to summarise.")
        }
        let names = current.voices?.names ?? [:]
        var summary = try await Summarizer.summary(of: current.transcript.named(names), using: request.provider,
                                                   language: request.language, complete: complete)
        try Task.checkCancellation()
        summary.basis = .init(transcript: current.transcript, names: names)
        return try TranscriptStore.publishSummary(summary, for: current.url, names: names)
    }
}
