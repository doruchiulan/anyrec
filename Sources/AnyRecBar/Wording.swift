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
        case .apple: return ready ? "Apple (on-device)" : "Apple (needs macOS 26)"
        case .whisper: return ready ? "whisper.cpp" : "whisper.cpp (not installed)"
        case .openai: return ready ? "OpenAI (uploads audio)" : "OpenAI (no API key)"
        }
    }

    /// Setting an engine up is a terminal job for now, so the two advisories that would
    /// have offered to do it here name the command that does.
    static func advisory(_ advisory: Advisory) -> String {
        switch advisory {
        case .whisperNotSetUp:
            "whisper is not set up yet. Run anyrec in a terminal to install it."
        case .openAIKeyMissing:
            "No OpenAI key. Set OPENAI_API_KEY, or run anyrec in a terminal to paste one."
        case .appleUnavailable:
            "Apple's engine needs macOS 26. Pick whisper or OpenAI instead."
        case .ffmpegMissing:
            "ffmpeg is missing, so there will be no call.mp4. Install it with brew install ffmpeg."
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
        case .installWhisper, .downloadModel:
            "Run anyrec in a terminal to set it up."
        case .installFFmpeg:
            "Install it with brew install ffmpeg."
        case .provideOpenAIKey:
            "Set OPENAI_API_KEY, or run anyrec in a terminal to paste one."
        }
    }
}
