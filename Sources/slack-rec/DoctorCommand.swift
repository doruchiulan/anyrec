import ArgumentParser
import Foundation
import SlackRecKit

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
            print("\(mark(false)) no call app window open — `slack-rec sources --all` lists the rest")
        } else {
            print("\(mark(true)) \(names.joined(separator: ", "))")
        }
    }

    /// Transcription is optional throughout: every line here is informational.
    private func transcriptionReport() async -> [String] {
        var lines: [String] = []

        if #available(macOS 26, *), AppleTranscriber.isAvailable {
            let locales = await AppleTranscriber.supportedLanguages()
            lines.append("\(mark(true)) apple speech, \(locales.count) languages, on-device")
        } else {
            lines.append("\(mark(false)) apple speech needs macOS 26 — whisper covers everything")
        }

        return lines + whisperReport() + [openAIReport()]
    }

    private func whisperReport() -> [String] {
        guard let whisper = WhisperTranscriber.binaryPath() else {
            return [
                "\(mark(false)) whisper not found — no Romanian transcripts",
                "    brew install whisper-cpp",
            ]
        }
        var lines = ["\(mark(true)) whisper at \(whisper)"]

        guard let model = WhisperTranscriber.defaultModel() else {
            lines.append("\(mark(false)) no whisper model in \(WhisperTranscriber.modelDirectory.path)")
            lines.append("    download one from https://huggingface.co/ggerganov/whisper.cpp")
            return lines
        }
        lines.append("\(mark(true)) whisper model \(model.lastPathComponent)")
        if WhisperTranscriber.voiceDetectionModel() == nil {
            lines.append("\(mark(false)) no silero VAD model — whisper timestamps will be coarse")
        }
        return lines
    }

    /// Informational either way: no key simply means `--engine openai` is unavailable.
    private func openAIReport() -> String {
        OpenAITranscriber.key() == nil
            ? "\(mark(false)) no OpenAI key — set OPENAI_API_KEY for --engine openai"
            : "\(mark(true)) OpenAI key found — --engine openai uploads the audio"
    }

    private func mark(_ ok: Bool) -> String { ok ? "ok  " : "MISSING" }
}
