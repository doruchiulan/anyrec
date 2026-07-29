import Foundation

public enum TranscriptionEngine: String, Sendable, CaseIterable {
    case auto
    case apple
    case whisper
    case openai

    /// The audio leaves the machine. `auto` never picks one of these.
    public var isRemote: Bool { self == .openai }
}

/// What one engine heard in one track.
public struct Speech: Sendable {
    public let utterances: [Utterance]
    /// The language the engine decided it was hearing, when it was not told.
    public let language: String?

    public init(utterances: [Utterance], language: String? = nil) {
        self.utterances = utterances
        self.language = language
    }
}

public protocol Transcriber: Sendable {
    var name: String { get }
    /// `regions` are where the speech is, for engines that would otherwise be handed
    /// room tone and invent sentences to fill it; ones that run their own voice
    /// detection ignore them. `language` is a BCP-47 tag; nil means let the engine decide.
    func speech(of url: URL, in regions: [Range<TimeInterval>], language: String?) async throws
        -> Speech
}

public enum TranscriptionError: Error, CustomStringConvertible {
    case noAudio
    case whisperNotFound
    case modelNotFound(URL)
    case ffmpegNotFound
    case engineFailed(engine: String, log: String)
    case unsupportedLanguage(engine: String, language: String)
    case appleUnavailable
    case openAIKeyMissing(URL)

    /// What would put the error right, when anything would. A fact rather than a
    /// sentence: "run `anyrec` with no arguments" is advice only a terminal can give,
    /// and the same missing model is a button somewhere else.
    public enum Remedy: Sendable, Equatable {
        case installWhisper
        case downloadModel(into: URL)
        case installFFmpeg
        case provideOpenAIKey(file: URL)
    }

    public var remedy: Remedy? {
        switch self {
        case .whisperNotFound: .installWhisper
        case .modelNotFound(let directory): .downloadModel(into: directory)
        case .ffmpegNotFound: .installFFmpeg
        case .openAIKeyMissing(let file): .provideOpenAIKey(file: file)
        default: nil
        }
    }

    /// The diagnosis only. What to do about it is `remedy`.
    public var description: String {
        switch self {
        case .noAudio:
            "No audio track was found to transcribe."
        case .whisperNotFound:
            "whisper-cli is not on PATH."
        case .modelNotFound(let directory):
            "No whisper model found in \(directory.path)."
        case .ffmpegNotFound:
            "ffmpeg is needed to feed whisper."
        case .engineFailed(let engine, let log):
            "\(engine) failed:\n\(log)"
        case .unsupportedLanguage(let engine, let language):
            "\(engine) has no model for \(language)."
        case .appleUnavailable:
            "Apple's on-device transcription needs macOS 26 or later."
        case .openAIKeyMissing:
            "No OpenAI API key."
        }
    }
}
