import Foundation

/// Hands the finished transcript to `claude -p`. Claude has no audio input, so
/// this is a text pass: it cleans up what the engine misheard and pulls out what
/// was decided.
///
/// It is also the only part of this tool that leaves the machine.
public enum Summarizer {
    public static func claudePath() -> String? {
        Shell.path(
            of: "claude",
            in: [NSHomeDirectory() + "/.claude/local", NSHomeDirectory() + "/.local/bin"]
        )
    }

    public static func prompt(for transcript: Transcript) -> String {
        """
        Below is a transcript of a call, produced by speech recognition, so expect \
        misheard words. "Me" is the person who recorded it; "Call" is everyone else.

        Write a summary in \(transcript.languageName ?? "the language the call was in"), \
        as Markdown, headings included, with these sections: summary (3-5 sentences), \
        decisions, action items (owner marked "Me" or "Call"), open questions. Leave out \
        any section with nothing in it.

        Correct obvious mishearings when the context makes the intent clear. Use nothing \
        but the transcript: do not name the speakers, do not read any file, and do not \
        add anything that was not said. Output the summary only.
        """
    }

    public static func summarize(_ transcript: Transcript) throws -> String {
        guard let claude = claudePath() else {
            throw TranscriptionError.engineFailed(
                engine: "claude", log: "The claude CLI is not on PATH.")
        }

        /// Run from an empty directory: claude reads the CLAUDE.md of wherever it
        /// starts, and that context ends up invented into the summary.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("anyrec-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let result = try Shell.run(
            claude, ["-p", prompt(for: transcript)],
            input: transcript.plainText, directory: scratch
        )
        guard result.succeeded else {
            throw TranscriptionError.engineFailed(
                engine: "claude", log: String(result.combined.suffix(2_000)))
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
