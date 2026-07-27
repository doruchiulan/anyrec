import Foundation

/// whisper.cpp behind `whisper-cli`. Slower than Apple's engine but it is the
/// only local option that speaks Romanian.
public struct WhisperTranscriber: Transcriber {
    public let name = "whisper"
    public let binary: String
    public let model: URL

    public static var modelDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/slack-rec/models")
    }

    public static func binaryPath() -> String? { Shell.path(of: "whisper-cli") }

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

    public init(model: URL? = nil, binary: String? = nil) throws {
        guard let found = binary ?? Self.binaryPath() else { throw TranscriptionError.whisperNotFound }
        guard let model = model ?? Self.defaultModel() else {
            throw TranscriptionError.modelNotFound(Self.modelDirectory)
        }
        self.binary = found
        self.model = model
    }

    /// Reads only the opening of the file: whisper decides on the first window anyway.
    public func detectLanguage(of url: URL) throws -> String? {
        let audio = try Self.wav(from: url, seconds: 30)
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }

        let result = try Shell.run(binary, ["-m", model.path, "-f", audio.path, "-dl"])
        guard
            let line = result.combined
                .split(separator: "\n")
                .last(where: { $0.contains("auto-detected language:") }),
            let tag = line.split(separator: ":").last?
                .split(separator: "(").first?
                .trimmingCharacters(in: .whitespaces),
            !tag.isEmpty
        else { return nil }
        return tag
    }

    /// `regions` are ignored: whisper.cpp runs silero over the audio itself.
    public func speech(
        of url: URL, in regions: [Range<TimeInterval>], language: String?
    ) async throws -> Speech {
        let audio = try Self.wav(from: url)
        let scratch = audio.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let prefix = scratch.appendingPathComponent("out")
        var arguments = [
            "-m", model.path, "-f", audio.path,
            "-l", language ?? "auto",
            "-oj", "-of", prefix.path, "-np",
        ]
        if let vad = Self.voiceDetectionModel() {
            arguments += ["--vad", "--vad-model", vad.path]
        }

        let result = try Shell.run(binary, arguments)
        guard result.succeeded else {
            throw TranscriptionError.engineFailed(
                engine: name, log: String(result.combined.suffix(2_000)))
        }

        let json = try Data(contentsOf: prefix.appendingPathExtension("json"))
        return Speech(utterances: try Self.parse(json))
    }

    static func parse(_ data: Data) throws -> [Utterance] {
        let payload = try JSONDecoder().decode(WhisperOutput.self, from: data)
        return payload.transcription.map {
            Utterance(
                start: TimeInterval($0.offsets.from) / 1_000,
                end: TimeInterval($0.offsets.to) / 1_000,
                text: $0.text
            )
        }
    }

    /// whisper-cli only reads flac/mp3/ogg/wav, and always at 16 kHz mono.
    private static func wav(from url: URL, seconds: Int? = nil) throws -> URL {
        guard let ffmpeg = Muxer.ffmpegPath() else { throw TranscriptionError.ffmpegNotFound }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("slack-rec-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let output = scratch.appendingPathComponent("audio.wav")

        var args = ["-nostdin", "-y", "-v", "error", "-i", url.path]
        if let seconds { args += ["-t", String(seconds)] }
        args += ["-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", output.path]

        let result = try Shell.run(ffmpeg, args)
        guard result.succeeded else {
            throw TranscriptionError.engineFailed(engine: "ffmpeg", log: result.combined)
        }
        return output
    }

    private static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

private struct WhisperOutput: Decodable {
    struct Segment: Decodable {
        struct Offsets: Decodable {
            let from: Int
            let to: Int
        }
        let offsets: Offsets
        let text: String
    }
    let transcription: [Segment]
}
