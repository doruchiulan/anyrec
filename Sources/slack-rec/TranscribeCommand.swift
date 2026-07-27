import ArgumentParser
import Foundation
import SlackRecKit

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Turn a recording into a speaker-labelled transcript.",
        discussion: """
        The tracks are mixed before transcription, so the engine orders the \
        conversation itself. Your lines are then found by measurement, not by \
        guessing: whichever track was louder while a line was said is the one that \
        said it.

        `apple` is the macOS 26 speech model — fast, thirty locales, no Romanian. \
        `whisper` is whisper.cpp, slower but it handles Romanian. `auto` detects the \
        language and picks between the two. All three run on this machine, and all \
        three report the far end as one voice.

        `openai` is the exception: it uploads the mixed audio and needs your own API \
        key in OPENAI_API_KEY. `auto` never picks it. It is also the only engine that \
        separates the other participants from each other — Slack sends them down one \
        stream, so nothing local can tell them apart.
        """
    )

    @Argument(help: "A recording folder or an audio file. Defaults to the newest recording.")
    var path: String?

    @Option(name: .long, help: "Which engine to use: auto, apple, whisper or openai.")
    var engine: TranscriptionEngine = .auto

    @Option(name: .long, help: "Language tag such as en or ro. Detected when omitted.")
    var language: String?

    @Option(name: .long, help: "Path to a whisper ggml model.")
    var model: String?

    @Option(name: .shortAndLong, help: "Where recordings live, when no path is given.")
    var output = Defaults.outputRoot

    @Flag(
        name: .long,
        help: "Summarise the transcript with claude -p. This sends the text to Anthropic."
    )
    var summarize = false

    @Flag(
        inversion: .prefixedNo,
        help: "Label each remote participant separately. --engine openai only."
    )
    var diarize = true

    func run() async throws {
        let source = try resolveSource()
        let job = TranscriptionService.Job(
            tracks: try tracks(of: source),
            engine: engine,
            language: language,
            model: model.map { URL(filePath: $0.expandingTilde) },
            diarize: diarize
        )

        let started = Date()
        let transcript = try await TranscriptionService.run(job) { print($0) }
        guard !transcript.isEmpty else {
            print("Nothing was said, or nothing was heard — no transcript written.")
            return
        }

        let directory = Self.isDirectory(source) ? source : source.deletingLastPathComponent()
        let name = "transcript-\(transcript.engine)"
        let written = try TranscriptionService.write(transcript, into: directory, named: name)

        print(report(transcript, started: started, written: written))
        if summarize { try writeSummary(transcript, into: directory, engine: transcript.engine) }
    }

    private func resolveSource() throws -> URL {
        if let path {
            let url = URL(filePath: path.expandingTilde)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("\(path) does not exist.")
            }
            return url
        }
        guard let latest = Self.newestRecording(in: URL(filePath: output.expandingTilde)) else {
            throw ValidationError(
                "No recordings in \(output). Pass a folder or an audio file instead.")
        }
        return latest
    }

    private func tracks(of source: URL) throws -> [TranscriptionService.Track] {
        guard Self.isDirectory(source) else {
            let speaker: Speaker = source.lastPathComponent.contains("microphone") ? .me : .others
            return [TranscriptionService.Track(url: source, speaker: speaker)]
        }
        let tracks = TranscriptionService.tracks(in: OutputPlan(directory: source))
        guard !tracks.isEmpty else {
            throw ValidationError("No audio tracks in \(source.lastPathComponent).")
        }
        return tracks
    }

    private static func newestRecording(in root: URL) -> URL? {
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
        return
            folders
            .filter { isDirectory($0) && $0.lastPathComponent.hasPrefix("slack-call-") }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `URL.hasDirectoryPath` only looks at the trailing slash, which a path typed
    /// on the command line will not have.
    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        return exists && directory.boolValue
    }

    /// The notes are said twice on purpose: once before the wait, and again here,
    /// where the minutes of engine output cannot bury them.
    private func report(_ transcript: Transcript, started: Date, written: [URL]) -> String {
        let elapsed = Date().timeIntervalSince(started)
        let speed = transcript.duration > 0 ? transcript.duration / elapsed : 0
        return """

            \(transcript.engine) · \(transcript.languageName) · \
            \(transcript.turns.count) turns over \(Int(transcript.duration))s of audio
            Took \(String(format: "%.1fs", elapsed))\
            \(speed > 0 ? String(format: " (%.1f× realtime)", speed) : "")
            \(written.map { "Wrote \($0.path)" }.joined(separator: "\n"))
            """ + transcript.notes.map { "\n\n\($0)" }.joined()
    }

    private func writeSummary(_ transcript: Transcript, into directory: URL, engine: String) throws {
        print("\nSummarising with claude — the transcript text is sent to Anthropic for this.")
        let summary = try Summarizer.summarize(transcript)
        let url = directory.appendingPathComponent("summary-\(engine).md")
        try summary.write(to: url, atomically: true, encoding: .utf8)
        print("Wrote \(url.path)")
    }
}
