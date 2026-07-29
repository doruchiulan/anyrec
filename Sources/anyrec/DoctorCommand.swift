import ArgumentParser
import Foundation
import AnyRecKit

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check permissions and dependencies before a real call."
    )

    func run() async throws {
        for (permission, granted) in Permissions.status(needsMicrophone: true) {
            print("\(mark(granted)) \(permission.rawValue)")
            if !granted { print("    \(permission.settingsURL.absoluteString)") }
        }

        if let ffmpeg = Muxer.ffmpegPath() {
            print("\(mark(true)) ffmpeg at \(ffmpeg)")
        } else {
            print("\(mark(false)) ffmpeg not found — no call.mp4 will be produced")
            print("    brew install ffmpeg")
        }

        for line in await transcriptionReport() { print(line) }

        guard Permissions.screenRecordingGranted() else { return }
        let open = try await ContentInventory.windows(bundleIDs: CallApps.bundleIDs)
        let names = Set(open.map(\.application)).sorted()
        if names.isEmpty {
            print("\(mark(false)) no call app window open — `anyrec sources --all` lists the rest")
        } else {
            print("\(mark(true)) \(names.joined(separator: ", "))")
        }
    }

    /// Transcription is optional throughout: every line here is informational.
    private func transcriptionReport() async -> [String] {
        let readiness = await Readiness.probe()
        var lines: [String] = []

        if readiness.of(.apple).isReady {
            lines.append("\(mark(true)) apple speech, on-device, and only these languages")
            lines.append("    \(AppleSpeech.describe(readiness.appleLanguages))")
        } else {
            lines.append("\(mark(false)) apple speech needs macOS 26 — whisper covers everything")
        }

        return lines + whisperReport() + openAIReport(readiness)
    }

    /// More detailed than `Readiness` is: this is the command whose whole job is
    /// saying which piece is missing.
    private func whisperReport() -> [String] {
        var lines: [String] = []

        if let whisper = WhisperTranscriber.binaryPath() {
            lines.append("\(mark(true)) whisper at \(whisper)")
        } else {
            lines.append("\(mark(false)) whisper not found — no Romanian transcripts")
        }
        if let model = WhisperTranscriber.defaultModel() {
            lines.append("\(mark(true)) whisper model \(model.lastPathComponent)")
        } else {
            lines.append(
                "\(mark(false)) no whisper model in \(WhisperTranscriber.modelDirectory.path)")
        }
        if WhisperTranscriber.voiceDetectionModel() == nil {
            lines.append("\(mark(false)) no silero VAD model — whisper timestamps will be coarse")
        }

        guard !WhisperSetup.pending().isEmpty else { return lines }
        return lines + [setupHint]
    }

    /// Informational either way: no key simply means `--engine openai` is unavailable.
    private func openAIReport(_ readiness: Readiness) -> [String] {
        guard !readiness.of(.openai).isReady else {
            return ["\(mark(true)) OpenAI key found — --engine openai uploads the audio"]
        }
        return [
            "\(mark(false)) no OpenAI key — --engine openai is unavailable",
            setupHint,
        ]
    }

    private var setupHint: String {
        "    run `anyrec` with no arguments — the Transcript row sets this up for you"
    }

    private func mark(_ ok: Bool) -> String { ok ? "ok  " : "MISSING" }
}
