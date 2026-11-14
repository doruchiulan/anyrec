import Foundation

/// Where the summary programs are found, and how a transcript is handed to them: one
/// line per utterance with its offset, so an action item can point at the second it was
/// said. The summary itself is `Summarizer.summary`, written by `SummaryPass`.
public enum Summarizer {
    public static func claudePath() -> String? {
        Shell.path(
            of: "claude",
            in: [NSHomeDirectory() + "/.claude/local", NSHomeDirectory() + "/.local/bin"]
        )
    }

    static func timedInput(for transcript: Transcript) -> String {
        transcript.utterances.map {
            "[\($0.start)s] \($0.speaker.label): \($0.text)"
        }.joined(separator: "\n")
    }
}
