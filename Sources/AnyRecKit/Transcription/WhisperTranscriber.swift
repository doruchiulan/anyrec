import Foundation
import whisper

/// whisper.cpp, inside the process: the framework its own CI builds, linked in, so
/// nothing is installed and the model is the only download. Slower than Parakeet, but
/// 99 languages to its 25.
public struct WhisperTranscriber: Transcriber {
    public let name = "whisper"
    public let model: URL

    public static var modelDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/anyrec/models")
    }

    /// The largest `.bin` in the model directory — bigger is better here, and a
    /// user who downloaded two models wants the good one.
    public static func defaultModel() -> URL? {
        models().filter { !isVoiceDetection($0) }.max { size(of: $0) < size(of: $1) }
    }

    /// Optional, and worth having: without it whisper stretches the first segment
    /// over the leading silence, which on a two-track call misorders the whole
    /// conversation. It also skips the long silences while the other side talks.
    public static func voiceDetectionModel() -> URL? {
        models().first(where: isVoiceDetection)
    }

    private static func models() -> [URL] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: modelDirectory, includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
        return files.filter { $0.pathExtension == "bin" }
    }

    private static func isVoiceDetection(_ url: URL) -> Bool {
        url.lastPathComponent.contains("silero")
    }

    public init(model: URL? = nil) throws {
        guard let model = model ?? Self.defaultModel() else {
            throw TranscriptionError.modelNotFound(Self.modelDirectory)
        }
        self.model = model
    }

    /// Reads only the opening of the file: whisper decides on the first window anyway.
    public func detectLanguage(of url: URL) throws -> String? {
        let samples = try AudioSamples.read(url, seconds: 30)
        let context = try Self.context(for: model)
        defer { whisper_free(context) }
        let threads = Self.threads
        let fed = samples.withUnsafeBufferPointer {
            whisper_pcm_to_mel(context, $0.baseAddress, Int32($0.count), threads)
        }
        guard fed == 0 else { return nil }
        let id = whisper_lang_auto_detect(context, 0, threads, nil)
        guard id >= 0, let tag = whisper_lang_str(id) else { return nil }
        return String(cString: tag)
    }

    /// `regions` are ignored: whisper.cpp runs silero over the audio itself.
    public func speech(
        of url: URL, in regions: [Range<TimeInterval>], language: String?
    ) async throws -> Speech {
        let samples = try AudioSamples.read(url)
        let context = try Self.context(for: model)
        defer { whisper_free(context) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Self.threads
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.detect_language = false
        /// The C strings have to outlive the call; `strdup` gives them a lifetime of
        /// their own, freed once whisper is done with them.
        let tag = strdup(language ?? "auto")
        defer { free(tag) }
        params.language = UnsafePointer(tag)
        var vadPath: UnsafeMutablePointer<CChar>?
        defer { free(vadPath) }
        if let vad = Self.voiceDetectionModel() {
            vadPath = strdup(vad.path)
            params.vad = true
            params.vad_model_path = UnsafePointer(vadPath)
            params.vad_params = whisper_vad_default_params()
        }

        let status = samples.withUnsafeBufferPointer {
            whisper_full(context, params, $0.baseAddress, Int32($0.count))
        }
        guard status == 0 else {
            throw TranscriptionError.engineFailed(engine: name, log: "whisper_full failed with \(status).")
        }

        let lines = (0..<whisper_full_n_segments(context)).compactMap { index in
            Self.utterance(
                from: whisper_full_get_segment_t0(context, index),
                to: whisper_full_get_segment_t1(context, index),
                text: whisper_full_get_segment_text(context, index).map { String(cString: $0) } ?? "")
        }
        return Speech(utterances: lines)
    }

    /// A segment's times come in centiseconds, its text with a leading space.
    static func utterance(from t0: Int64, to t1: Int64, text: String) -> Utterance? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Utterance(start: TimeInterval(t0) / 100, end: TimeInterval(t1) / 100, text: trimmed)
    }

    private static func context(for model: URL) throws -> OpaquePointer {
        /// whisper narrates model loading and Metal setup on stderr, which in the
        /// terminal lands on the setup screen's alternate screen.
        whisper_log_set({ _, _, _ in }, nil)
        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let context = whisper_init_from_file_with_params(model.path, params) else {
            throw TranscriptionError.engineFailed(
                engine: "whisper", log: "The model could not be loaded: \(model.lastPathComponent)")
        }
        return context
    }

    private static let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))

    private static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
