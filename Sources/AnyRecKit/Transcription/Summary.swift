import Foundation

/// A call's summary as data, so an interface can lay it out: the overview, what was
/// decided, and what somebody has to do — each action with the second it was said.
public struct Summary: Sendable, Equatable, Codable {
    public struct Action: Sendable, Equatable, Codable {
        public var task: String
        public var owner: String?
        /// Seconds into the recording, for jumping to the moment.
        public var at: TimeInterval?
        public var done = false

        public init(task: String, owner: String? = nil, at: TimeInterval? = nil, done: Bool = false) {
            self.task = task
            self.owner = owner
            self.at = at
            self.done = done
        }
    }

    public var overview: String
    public var decisions: [String]
    public var actions: [Action]
    /// Who wrote it, by the name the settings show.
    public var provider: String

    public init(overview: String, decisions: [String], actions: [Action], provider: String) {
        self.overview = overview
        self.decisions = decisions
        self.actions = actions
        self.provider = provider
    }

    /// The summary beside the transcript it came from. Written next to a Markdown copy
    /// so `anyrec` and a text editor read the same thing.
    public static func fileName(engine: String) -> String { "summary-\(engine).json" }

    public static func read(_ url: URL) -> Summary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Summary.self, from: data)
    }

    public func write(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try markdown.write(
            to: url.deletingPathExtension().appendingPathExtension("md"),
            atomically: true, encoding: .utf8)
    }

    public var markdown: String {
        var parts = [overview]
        if !decisions.isEmpty {
            parts.append("## Decisions\n" + decisions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !actions.isEmpty {
            parts.append(
                "## Action items\n"
                    + actions.map {
                        "- [\($0.done ? "x" : " ")] \($0.task)"
                            + ($0.owner.map { " — \($0)" } ?? "")
                    }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// Models wrap JSON in fences and a sentence; the object is whatever lies between the
    /// outermost braces. Nil when there is none, which is a failure worth saying.
    static func parse(_ output: String, provider: String) -> Summary? {
        guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"),
            open < close,
            let data = String(output[open...close]).data(using: .utf8),
            let reply = try? JSONDecoder().decode(Reply.self, from: data)
        else { return nil }
        return Summary(
            overview: reply.overview, decisions: reply.decisions ?? [],
            actions: (reply.actions ?? []).map {
                Action(task: $0.task, owner: $0.owner, at: $0.at)
            },
            provider: provider)
    }

    private struct Reply: Decodable {
        struct Item: Decodable {
            let task: String
            let owner: String?
            let at: TimeInterval?
        }
        let overview: String
        let decisions: [String]?
        let actions: [Item]?
    }
}

/// Who can write the summary. Each provider is a program on this machine or an API behind
/// the user's own key; the transcript text goes to it and the audio never does.
public enum SummaryProvider: String, Sendable, CaseIterable, Codable {
    case claude, codex, openai, gemini

    public var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .openai: "OpenAI API"
        case .gemini: "Gemini CLI"
        }
    }

    /// Whose servers the text lands on, for the sentence that says so.
    public var company: String {
        switch self {
        case .claude: "Anthropic"
        case .codex, .openai: "OpenAI"
        case .gemini: "Google"
        }
    }

    var executable: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        case .openai: nil
        }
    }

    /// The program's path, or nil when it is not installed; the API has none.
    public var path: String? {
        switch self {
        case .claude: Summarizer.claudePath()
        case .codex, .gemini:
            executable.flatMap {
                Shell.path(of: $0, in: [NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.npm-global/bin"])
            }
        case .openai: nil
        }
    }

    public var isAvailable: Bool {
        self == .openai ? OpenAIKey.current() != nil : path != nil
    }

    /// What stands between this provider and working, in a few words.
    public var detail: String {
        switch self {
        case .openai: OpenAIKey.current() != nil ? "Your key from Engines" : "Needs an OpenAI key"
        default:
            path.map { "\(executable ?? "") · found in \(($0 as NSString).deletingLastPathComponent)" }
                ?? "Not installed"
        }
    }

    /// The first provider that can run, in the order above.
    public static var firstAvailable: SummaryProvider? { allCases.first(where: \.isAvailable) }
}

extension Summarizer {
    /// The structured summary, written by `provider`. `language` is a name like "English",
    /// or nil to follow the call.
    public static func summary(
        of transcript: Transcript, using provider: SummaryProvider, language: String? = nil
    ) async throws -> Summary {
        try await summary(of: transcript, using: provider, language: language) {
            try await LLMClient.complete(instructions: $0, text: $1, using: $2)
        }
    }

    static func summary(
        of transcript: Transcript, using provider: SummaryProvider, language: String? = nil,
        complete: @Sendable (String, String, SummaryProvider) async throws -> String
    ) async throws -> Summary {
        let instructions = structuredPrompt(for: transcript, language: language)
        let output = try await complete(instructions, timedInput(for: transcript), provider)
        guard let summary = Summary.parse(output, provider: provider.name) else {
            throw TranscriptionError.engineFailed(
                engine: provider.rawValue,
                log: "It did not answer with a summary: \(String(output.suffix(500)))")
        }
        return summary
    }

    static func structuredPrompt(for transcript: Transcript, language: String?) -> String {
        """
        Below is a transcript of a call, produced by speech recognition, so expect \
        misheard words. Each line starts with its recording offset in seconds, such as [754.25s].

        Write the summary in \(language ?? transcript.languageName ?? "the language the call was in"). \
        Answer with one JSON object and nothing else, shaped exactly like this:
        {"overview": "2-3 sentences on what the call covered and where it landed",
         "decisions": ["a decision taken in the call"],
         "actions": [{"task": "what has to be done", "owner": "who, as named in the transcript", \
        "at": 754}]}
        "at" is the numeric timestamp of the transcript line where the action was agreed. \
        Copy that offset in seconds; omit "at" if no supporting line can be located. \
        Never use zero as a placeholder for an unknown time. Leave "decisions" or \
        "actions" empty when there are none. Correct obvious mishearings when the context \
        makes the intent clear. Use nothing but the transcript: do not read any file and do \
        not add anything that was not said.
        """
    }

}
