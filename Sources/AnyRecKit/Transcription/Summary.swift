import CryptoKit
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

    /// What a summary was written from: the transcript's words and who said each, and
    /// the names voices had at the time. Speakers that had no name were written by their
    /// label ("Speaker B"), and those labels are filled in when the summary is shown, so
    /// naming someone later needs no second call to the model. Nil for a summary written
    /// before this existed, which is shown as it is and never called stale.
    public struct Basis: Codable, Equatable, Sendable {
        /// SHA-256 of every line's speaker label (unnamed) and text.
        public let text: String
        /// Letter → name, for the voices that had a name when it was written.
        public let names: [String: String]

        public init(text: String, names: [String: String]) {
            self.text = text
            self.names = names
        }

        public init(transcript: Transcript, names: [String: String]) {
            self.init(text: Self.digest(transcript), names: names)
        }

        static func digest(_ transcript: Transcript) -> String {
            var hash = SHA256()
            for line in transcript.utterances {
                hash.update(data: Data((line.speaker.label + "\u{1F}" + line.text + "\u{1E}").utf8))
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Why a summary no longer describes the transcript, as a fact for an interface.
    public enum Staleness: Sendable, Equatable {
        case current
        /// The words, or who said them, changed since it was written.
        case transcriptChanged
        /// A voice named when it was written now has another name, or none.
        case nameChanged
    }

    public var overview: String
    public var decisions: [String]
    public var actions: [Action]
    /// Who wrote it, by the name the settings show.
    public var provider: String
    public var basis: Basis?

    public init(overview: String, decisions: [String], actions: [Action], provider: String, basis: Basis? = nil) {
        self.overview = overview
        self.decisions = decisions
        self.actions = actions
        self.provider = provider
        self.basis = basis
    }

    public func staleness(of transcript: Transcript, names: [String: String]) -> Staleness {
        guard let basis else { return .current }
        if basis.text != Basis.digest(transcript) { return .transcriptChanged }
        if basis.names.contains(where: { names[$0.key] != $0.value }) { return .nameChanged }
        return .current
    }

    /// The summary as it reads now: every "Speaker X" label whose voice has since been
    /// named carries the name, in the prose and in the owners.
    public func named(_ names: [String: String]) -> Summary {
        guard !names.isEmpty else { return self }
        let fill = { (text: String) in Self.fill(text, names) }
        var result = self
        result.overview = fill(overview)
        result.decisions = decisions.map(fill)
        result.actions = actions.map { action in
            var action = action
            action.task = fill(action.task)
            action.owner = action.owner.map(fill)
            return action
        }
        return result
    }

    private static let label = try! NSRegularExpression(pattern: #"\bSpeaker ([A-Z]|[0-9]+)\b"#)

    static func fill(_ text: String, _ names: [String: String]) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        for match in label.matches(in: text, range: range).reversed() {
            guard let whole = Range(match.range, in: text), let letter = Range(match.range(at: 1), in: text),
                  let name = names[String(text[letter])] else { continue }
            result.replaceSubrange(whole, with: name)
        }
        /// A summary written before the owner was known calls them by the label, "Me".
        if let me = names[RecordingVoices.meKey] {
            let filled = NSRange(result.startIndex..., in: result)
            result = meLabel.stringByReplacingMatches(in: result, range: filled, withTemplate: NSRegularExpression.escapedTemplate(for: me))
        }
        return result
    }

    private static let meLabel = try! NSRegularExpression(pattern: #"\bMe\b"#)

    /// The summary beside the transcript it came from. Written next to a Markdown copy
    /// so `anyrec` and a text editor read the same thing.
    public static func fileName(engine: String) -> String { "summary-\(engine).json" }

    public static func read(_ url: URL) -> Summary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Summary.self, from: data)
    }

    /// The JSON keeps the labels; the Markdown beside it reads with `names` filled in.
    public func write(to url: URL, names: [String: String] = [:]) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try renderMarkdown(beside: url, names: names)
    }

    public func renderMarkdown(beside url: URL, names: [String: String]) throws {
        try named(names).markdown.write(
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
        misheard words. Each line starts with its recording offset in seconds, such as [754.25s]. \
        "Me" is the person who recorded the call; "Call" is someone on the far end who was not told apart. \
        A speaker nobody has named yet appears by a label such as "Speaker B": refer to that speaker by \
        exactly that label, in the overview, the decisions and the owners, and never guess a name for them. \
        Use other speakers' names exactly as they appear.

        Write the summary in \(language ?? transcript.languageName ?? "the language the call was in"). \
        Answer with one JSON object and nothing else, shaped exactly like this:
        {"overview": "2-3 sentences on what the call covered and where it landed",
         "decisions": ["a decision taken in the call"],
         "actions": [{"task": "what has to be done", "owner": "who, as labelled in the transcript", \
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
