import Foundation
import AnyRecKit

/// How a configuration reads on the setup screen, and how ←→ change it. Padded rows
/// and arrow-key cycling are the terminal's business, not the recording's.
extension RecordingConfiguration {
    static let stopChoices: [TimeInterval?] = [nil, 900, 1_800, 2_700, 3_600, 7_200]
    static let transcribeChoices: [TranscriptionEngine?] = [nil] + TranscriptionEngine.allCases

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
        return Readiness.ffmpegInstalled ? "On — call.mp4" : "On — but ffmpeg is missing"
    }

    func transcribeLabel(_ readiness: Readiness) -> String {
        guard let engine = transcribe else { return "Off" }
        switch (engine, readiness.of(engine).isReady) {
        case (.auto, _): return "On — pick the engine by language"
        case (.apple, true): return "On — Apple, on-device, \(readiness.appleLanguages.count) languages"
        case (.apple, false): return "On — Apple, which needs macOS 26"
        case (.whisper, true): return "On — whisper.cpp"
        case (.whisper, false): return "On — whisper.cpp, not installed yet"
        case (.openai, true): return "On — OpenAI, uploads the audio"
        case (.openai, false): return "On — OpenAI, but no API key is set"
        }
    }

    mutating func cycleStop(by delta: Int) {
        stopAfter = Self.stopChoices[Self.next(Self.stopChoices, from: stopAfter, by: delta)]
    }

    mutating func cycleTranscribe(by delta: Int) {
        transcribe =
            Self.transcribeChoices[Self.next(Self.transcribeChoices, from: transcribe, by: delta)]
    }

    private static func next<T: Equatable>(_ choices: [T?], from current: T?, by delta: Int) -> Int {
        let index = choices.firstIndex { $0 == current } ?? 0
        return (index + delta + choices.count) % choices.count
    }
}

/// The advisory in the terminal's words: ⏎ and named rows are what this screen has.
func phrase(_ advisory: Advisory) -> String {
    switch advisory {
    case .whisperNotSetUp:
        "whisper is not set up yet — ⏎ on Transcript installs it for you."
    case .openAIKeyMissing:
        "No OpenAI key — ⏎ on Transcript lets you paste one."
    case .appleUnavailable:
        "Apple's engine needs macOS 26 — pick whisper or OpenAI instead."
    case .ffmpegMissing:
        "ffmpeg is missing, so there will be no call.mp4: brew install ffmpeg"
    case .openAIUploadsAudio:
        "OpenAI transcribes off your machine — both audio tracks are uploaded."
    case .appleCoversSomeLanguages(let count):
        "Apple has models for \(count) languages — ⏎ lists them, whisper covers the rest."
    case .bothAudioTracksOff:
        "Both audio tracks are off — this will be a silent video."
    }
}
