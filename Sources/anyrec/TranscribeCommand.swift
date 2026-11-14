import ArgumentParser
import Foundation
import AnyRecKit

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Turn a recording into a speaker-labelled transcript.",
        discussion: """
        The tracks are mixed before transcription, so the engine orders the \
        conversation itself. Your lines are then found by measurement, not by \
        guessing: whichever track was louder while a line was said is the one that \
        said it.

        `parakeet`, `apple` and `whisper` run on this machine. `auto` tries Parakeet \
        first, then Apple when it supports the language, then Whisper. It never \
        uploads audio.

        `openai` is the exception: it uploads the mixed audio and needs your own API \
        key in OPENAI_API_KEY. The optional speaker model separates remote voices \
        on this Mac after any engine finishes. Each successful run saves a new \
        transcript version and selects it, preserving previous versions.

        This runs the same steps as the app: transcript, voices, then --review and \
        --summarize when asked. Both send the transcript's text, never its audio, to \
        --provider.
        """
    )

    @Argument(help: "A recording folder or an audio file. Defaults to the newest recording.")
    var path: String?

    @Option(name: .long, help: "Which engine to use: auto, parakeet, apple, whisper or openai.")
    var engine: TranscriptionEngine = .auto

    @Option(name: .long, help: "Language tag such as en or ro. Detected when omitted.")
    var language: String?

    @Option(name: .long, help: "Path to a whisper ggml model.")
    var model: String?

    @Option(name: .shortAndLong, help: "Where recordings live, when no path is given.")
    var output = Defaults.outputRoot

    @Flag(
        name: .long,
        help: "Write a summary afterwards. This sends the transcript text (never the audio) to --provider."
    )
    var summarize = false

    @Flag(
        name: .long,
        help: "Review the wording with an LLM afterwards. This sends the transcript text to --provider."
    )
    var review = false

    @Flag(
        name: .long,
        help: "With --review, also run the other enabled on-device engines and let the reviewer compare them."
    )
    var compareEngines = false

    @Option(name: .long, help: "Who reviews and summarises: claude, codex, openai or gemini.")
    var provider: SummaryProvider = .claude

    @Option(name: .long, help: "The summary's language, such as English. Follows the call when omitted.")
    var summaryLanguage: String?

    @Flag(
        inversion: .prefixedNo,
        help: "Label each remote participant separately. --engine openai only."
    )
    var diarize = true

    func run() async throws {
        let source = try resolveSource()
        let directory = Recordings.isDirectory(source) ? source : source.deletingLastPathComponent()
        let job = TranscriptionService.Job(
            tracks: try tracks(of: source),
            engine: engine,
            language: language,
            model: model.map { URL(filePath: $0.expandingTilde) },
            diarize: diarize,
            live: MicrophoneLive.read(OutputPlan(directory: directory).microphoneLive),
            participants: CallParticipants.read(in: directory)
        )
        var options = TranscriptionOptions()
        options.enabledEngines = Set(TranscriptionEngine.allCases)
        options.comparisonEngines = [.parakeet, .apple, .whisper]
        options.identifySpeakers = diarize
        options.review = review
        options.compareEngines = compareEngines
        options.reviewProvider = provider
        if review || summarize {
            print("The transcript text (never the audio) is sent to \(provider.company) for "
                  + [review ? "review" : nil, summarize ? "a summary" : nil].compactMap { $0 }.joined(separator: " and ") + ".")
        }

        let started = Date()
        let outcome = await TranscriptPass.run(job, in: directory, options: options,
                                               summary: summarize ? SummaryRequest(provider: provider, language: summaryLanguage) : nil) {
            print($0)
        }
        switch outcome {
        case .nothingHeard:
            print("Nothing was said, or nothing was heard — no transcript written.")
        case .failed(let reason, let remedy):
            throw Explained(message: ([reason] + (remedy.map { [$0.advice] } ?? [])).joined(separator: "\n"))
        case .written(let files, _, let voices, let summary):
            if let current = TranscriptStore.current(in: directory) {
                print(report(current.transcript, started: started, written: files))
            }
            switch summary {
            case .written(let url): print("Wrote \(url.path)\nWrote \(url.deletingPathExtension().appendingPathExtension("md").path)")
            case .failed(let reason): print("\nNo summary: \(reason)")
            case nil: break
            }
            SpeakerPrompt.offer(voices, in: directory)
        }
    }

    private func resolveSource() throws -> URL {
        if let path {
            let url = URL(filePath: path.expandingTilde)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("\(path) does not exist.")
            }
            return url
        }
        guard let latest = Recordings.newest(in: URL(filePath: output.expandingTilde)) else {
            throw ValidationError(
                "No recordings in \(output). Pass a folder or an audio file instead.")
        }
        return latest
    }

    private func tracks(of source: URL) throws -> [TranscriptionService.Track] {
        guard Recordings.isDirectory(source) else {
            let speaker: Speaker = source.lastPathComponent.contains("microphone") ? .me : .others
            return [TranscriptionService.Track(url: source, speaker: speaker)]
        }
        let tracks = TranscriptionService.tracks(in: OutputPlan(directory: source))
        guard !tracks.isEmpty else {
            throw ValidationError("No audio tracks in \(source.lastPathComponent).")
        }
        return tracks
    }

    /// The notes are said twice on purpose: once before the wait, and again here,
    /// where the minutes of engine output cannot bury them.
    private func report(_ transcript: Transcript, started: Date, written: [URL]) -> String {
        let elapsed = Date().timeIntervalSince(started)
        let speed = transcript.duration > 0 ? transcript.duration / elapsed : 0
        let summary = [
            transcript.engine, transcript.languageName,
            "\(transcript.turns.count) turns over \(Int(transcript.duration))s of audio",
        ].compactMap { $0 }.joined(separator: " · ")
        return """

            \(summary)
            Took \(String(format: "%.1fs", elapsed))\
            \(speed > 0 ? String(format: " (%.1f× realtime)", speed) : "")
            \(written.map { "Wrote \($0.path)" }.joined(separator: "\n"))
            """ + transcript.notes.map { "\n\n\($0)" }.joined()
    }
}
