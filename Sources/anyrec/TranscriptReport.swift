import Foundation
import AnyRecKit

/// The transcription pass, said out loud. The pass itself cannot fail a recording;
/// this only decides how its outcome reads on a terminal.
enum TranscriptReport {
    static func follow(_ session: RecordingSession) async {
        guard session.configuration.transcribe != nil else { return }
        print("")
        if let outcome = await session.transcript(progress: { print("  \($0)") }) {
            print(render(outcome))
        }
    }

    static func render(_ outcome: TranscriptOutcome) -> String {
        switch outcome {
        case .written(let files, let notes):
            (files.map { "  Wrote \($0.path)" } + notes.map { "\n  \($0)" }).joined(separator: "\n")
        case .nothingHeard:
            "  Nothing was heard, so there is no transcript."
        case .failed(let reason, let remedy):
            (["  No transcript: \(reason)"] + (remedy.map { [indented($0.advice)] } ?? [])
                + ["  The recording is untouched — retry with `anyrec transcribe`."])
                .joined(separator: "\n")
        }
    }

    private static func indented(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }.joined(separator: "\n")
    }
}

extension TranscriptionError.Remedy {
    /// The way out of the error, worded for a terminal. Somewhere with buttons would
    /// say the same four things differently.
    var advice: String {
        switch self {
        case .installWhisper:
            "Run `anyrec` with no arguments to install it, or `brew install whisper-cpp`."
        case .downloadModel(let directory):
            "Run `anyrec` with no arguments to download one into \(directory.path)."
        case .installFFmpeg:
            "Install it with `brew install ffmpeg`."
        case .provideOpenAIKey(let file):
            """
            Run `anyrec` with no arguments to paste one, or bring your own:
              export OPENAI_API_KEY=sk-…
              printf %s sk-… > "\(file.path)"
            """
        }
    }
}

/// Carries an already-worded message out to the command line.
private struct Explained: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A `TranscriptionError` on its way out of a command carries only its diagnosis.
/// This is where the terminal's way out of it is added.
func withRemedy<T>(_ work: () async throws -> T) async throws -> T {
    do {
        return try await work()
    } catch let error as TranscriptionError {
        guard let remedy = error.remedy else { throw error }
        throw Explained(message: "\(error)\n\(remedy.advice)")
    }
}
