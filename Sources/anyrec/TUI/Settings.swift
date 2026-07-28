import Foundation
import AnyRecKit

enum Defaults {
    static let outputRoot = "~/Desktop/AnyRec Recordings"
}

struct CaptureChoice: Equatable {
    let target: CaptureTarget
    let label: String
}

/// Everything the setup screen edits, and the shapes the recorder wants it in.
struct Settings {
    /// Nil until a window or display is picked: recording the wrong thing is worse
    /// than recording nothing, so there is no default.
    var capture: CaptureChoice?
    /// Nil means the microphone is not recorded. The device is always explicit, so
    /// another app switching the system default mid-call cannot redirect the capture.
    var microphone: AudioInputDevice?
    var systemAudio = true
    var stopAfter: TimeInterval?
    var mux = true
    /// Nil means no transcript is produced.
    var transcribe: TranscriptionEngine?
    var fps = 30
    var codec: VideoCodec = .h264
    var outputRoot: String
    /// What Apple's on-device engine can transcribe here. Empty means it cannot run at
    /// all. Looked up once, before raw mode, because the answer is an await away.
    var appleLanguages: [String] = []

    static let stopChoices: [TimeInterval?] = [nil, 900, 1_800, 2_700, 3_600, 7_200]
    static let transcribeChoices: [TranscriptionEngine?] = [nil] + TranscriptionEngine.allCases

    var options: CaptureOptions {
        CaptureOptions(
            fps: fps,
            codec: codec,
            captureSystemAudio: systemAudio,
            captureMicrophone: microphone != nil,
            microphoneDeviceID: microphone?.id,
            showsCursor: true
        )
    }

    var captureLabel: String { capture?.label ?? "Nothing picked yet" }

    var microphoneLabel: String {
        microphone.map { "\($0.name)\($0.isDefault ? " (system default)" : "")" } ?? "Off"
    }

    var stopLabel: String {
        guard let stopAfter else { return "when I press q" }
        let minutes = Int(stopAfter) / 60
        return minutes % 60 == 0 ? "after \(minutes / 60)h" : "after \(minutes)m"
    }

    var muxLabel: String {
        guard mux else { return "Off — separate tracks only" }
        return Muxer.ffmpegPath() == nil ? "On — but ffmpeg is missing" : "On — call.mp4"
    }

    var transcribeLabel: String {
        switch transcribe {
        case nil: "Off"
        case .auto: "On — pick the engine by language"
        case .apple:
            appleLanguages.isEmpty
                ? "On — Apple, which needs macOS 26"
                : "On — Apple, on-device, \(appleLanguages.count) languages"
        case .whisper:
            WhisperSetup.pending().isEmpty
                ? "On — whisper.cpp" : "On — whisper.cpp, not installed yet"
        case .openai:
            OpenAIKey.current() == nil
                ? "On — OpenAI, but no API key is set" : "On — OpenAI, uploads the audio"
        }
    }

    mutating func cycleStop(by delta: Int) {
        let index = Self.stopChoices.firstIndex { $0 == stopAfter } ?? 0
        let next = (index + delta + Self.stopChoices.count) % Self.stopChoices.count
        stopAfter = Self.stopChoices[next]
    }

    mutating func cycleTranscribe(by delta: Int) {
        let index = Self.transcribeChoices.firstIndex { $0 == transcribe } ?? 0
        let next = (index + delta + Self.transcribeChoices.count) % Self.transcribeChoices.count
        transcribe = Self.transcribeChoices[next]
    }
}
