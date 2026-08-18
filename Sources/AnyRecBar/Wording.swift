import Foundation
import AnyRecKit

/// The Kit's facts in the menu bar's words. The terminal says "⏎ on Transcript"; a
/// panel has no ⏎ and no row to press it on, so the same advisory says where to go
/// instead. Nothing here draws anything, which is what makes it the tested part.
enum Wording {
    static func clock(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        return total < 3_600
            ? String(format: "%02d:%02d", total / 60, total % 60)
            : String(format: "%d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
    }

    static func remaining(_ left: TimeInterval) -> String {
        let total = Int(left)
        return total >= 60 ? "\(total / 60)m left" : "\(total)s left"
    }

    static func microphone(_ device: AudioInputDevice?) -> String {
        guard let device else { return "Off" }
        return device.isDefault ? "\(device.name) (default)" : device.name
    }

    static func stopAfter(_ interval: TimeInterval?) -> String {
        guard let interval else { return "When I stop it" }
        let minutes = Int(interval) / 60
        return minutes % 60 == 0 ? "After \(minutes / 60)h" : "After \(minutes)m"
    }

    /// Engines are picked from a menu that shows every option at once, so each one says
    /// what it is and, when it cannot run, that it cannot.
    static func engine(_ engine: TranscriptionEngine?, _ readiness: Readiness) -> String {
        guard let engine else { return "Off" }
        let ready = readiness.of(engine).isReady
        switch engine {
        case .auto: return "Automatic"
        case .apple: return ready ? "Apple (on device, English only)" : "Apple (needs macOS 26)"
        case .whisper: return ready ? "Whisper (on device)" : "Whisper (not installed)"
        case .openai: return ready ? "OpenAI (uploads audio)" : "OpenAI (no API key)"
        }
    }

    /// The settings window lists the engines by name, with what stands between each one
    /// and running. The panel's row says both at once because it is a menu; here there
    /// are two columns to put them in.
    static func engineName(_ engine: TranscriptionEngine) -> String {
        switch engine {
        case .auto: "Automatic"
        case .apple: "Apple"
        case .whisper: "Whisper"
        case .openai: "OpenAI"
        }
    }

    static func engineStatus(_ engine: TranscriptionEngine, _ readiness: Readiness) -> String {
        guard !readiness.of(engine).isReady else {
            return engine == .openai ? "Ready — uploads audio" : "Ready — on device"
        }
        switch engine {
        case .auto: return "Nothing installed to run it"
        case .apple: return "Needs macOS 26"
        case .whisper: return "Not installed"
        case .openai: return "No API key"
        }
    }

    /// What pressing it will fetch, on the button rather than after it. Installs weigh
    /// nothing to download, so a step list that is all installs says so instead.
    static func install(_ steps: [WhisperSetup.Step]) -> String {
        let bytes = WhisperSetup.downloadSize(of: steps)
        return bytes > 0 ? "Install — downloads \(AssetDownload.describe(bytes))" : "Install"
    }

    static func keyOutcome(_ outcome: OpenAIKey.StoreOutcome) -> String {
        switch outcome {
        case .saved: "Saved. OpenAI accepted it."
        case .savedUnverified(let reason): "Saved without checking it: \(reason)"
        case .savedButShadowed: "Saved, but OPENAI_API_KEY in your environment wins over it."
        case .rejected(let complaint): "Not saved — \(complaint)"
        case .notSaved(let reason): "Not saved — \(reason)"
        }
    }

    static func wasRefused(_ outcome: OpenAIKey.StoreOutcome) -> Bool {
        switch outcome {
        case .rejected, .notSaved: true
        case .saved, .savedUnverified, .savedButShadowed: false
        }
    }

    /// Both of the advisories that name a way out now have a window to name instead of
    /// a command: the app is installable on its own, so "run anyrec in a terminal" was
    /// advice a cask user could not take.
    static func advisory(_ advisory: Advisory) -> String {
        switch advisory {
        case .whisperNotSetUp:
            "whisper is not set up yet. Install it in Settings › Transcription."
        case .openAIKeyMissing:
            "No OpenAI key. Set OPENAI_API_KEY, or paste one in Settings › Transcription."
        case .appleUnavailable:
            "Apple's engine needs macOS 26. Pick whisper or OpenAI instead."
        case .ffmpegMissing:
            "ffmpeg is missing, so there will be no call.mp4. Install it in Settings › Transcription."
        case .openAIUploadsAudio:
            "OpenAI transcribes off your machine — both audio tracks are uploaded."
        case .appleCoversSomeLanguages(let count):
            "Apple has models for \(count) languages; whisper covers the rest."
        case .bothAudioTracksOff:
            "Both audio tracks are off — this will be a silent video."
        }
    }

    static func merge(_ outcome: MergeOutcome) -> String {
        switch outcome {
        case .merged: "Merged into call.mp4"
        case .notRequested: "The tracks were left separate, as asked"
        case .ffmpegMissing: "No call.mp4: ffmpeg is not installed"
        case .failed(let reason): "The merge failed: \(reason)"
        }
    }

    static func transcript(_ outcome: TranscriptOutcome) -> String {
        switch outcome {
        case .written(let files, _):
            "Wrote \(files.count == 1 ? "a transcript" : "\(files.count) transcript files")"
        case .nothingHeard:
            "Nothing was heard, so there is no transcript"
        case .failed(let reason, let remedy):
            ["No transcript: \(reason)", remedy.map(self.remedy)]
                .compactMap { $0 }.joined(separator: " ")
        }
    }

    static func remedy(_ remedy: TranscriptionError.Remedy) -> String {
        switch remedy {
        case .installWhisper, .downloadModel, .installFFmpeg:
            "Set it up in Settings › Transcription."
        case .provideOpenAIKey:
            "Set OPENAI_API_KEY, or paste a key in Settings › Transcription."
        }
    }
}
