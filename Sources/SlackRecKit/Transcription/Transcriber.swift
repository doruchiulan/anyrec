import Foundation

public enum TranscriptionEngine: String, Sendable, CaseIterable {
    case auto
    case apple
    case whisper
}

public protocol Transcriber: Sendable {
    var name: String { get }
    /// `language` is a BCP-47 tag; nil means let the engine decide.
    func utterances(of url: URL, language: String?) async throws -> [Utterance]
}

public enum TranscriptionError: Error, CustomStringConvertible {
    case noAudio
    case whisperNotFound
    case modelNotFound(URL)
    case ffmpegNotFound
    case engineFailed(engine: String, log: String)
    case unsupportedLanguage(engine: String, language: String)
    case appleUnavailable

    public var description: String {
        switch self {
        case .noAudio:
            "No audio track was found to transcribe."
        case .whisperNotFound:
            "whisper-cli is not on PATH. Install it with `brew install whisper-cpp`."
        case .modelNotFound(let directory):
            """
            No whisper model found in \(directory.path).
            Download one, for example:
              curl -L -o "\(directory.path)/ggml-large-v3-turbo-q5_0.bin" \\
                https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
            """
        case .ffmpegNotFound:
            "ffmpeg is needed to feed whisper. Install it with `brew install ffmpeg`."
        case .engineFailed(let engine, let log):
            "\(engine) failed:\n\(log)"
        case .unsupportedLanguage(let engine, let language):
            "\(engine) has no model for \(language)."
        case .appleUnavailable:
            "Apple's on-device transcription needs macOS 26 or later."
        }
    }
}
