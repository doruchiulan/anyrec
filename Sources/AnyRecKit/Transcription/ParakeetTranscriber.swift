import AVFoundation
import FluidAudio
import Foundation

/// NVIDIA's Parakeet TDT 0.6B v3, run on this Mac by FluidAudio on CoreML: twenty-five
/// European languages, Romanian among them, at many times real time on Apple silicon.
/// The on-device engine that needs nothing installed — only its model downloaded, which
/// choosing it does. It tells the language itself, so none is detected for it first.
public struct ParakeetTranscriber: Transcriber {
    public let name = "parakeet"

    public init() throws {
        guard ParakeetSetup.isReady else { throw TranscriptionError.parakeetNotSetUp }
    }

    /// `regions` are not handed to the model — it reads the file whole, and a TDT model
    /// does not invent over silence the way whisper does — but a line it places where
    /// nobody was speaking is dropped, since that is the only kind it gets wrong there.
    public func speech(
        of url: URL, in regions: [Range<TimeInterval>], language: String?
    ) async throws -> Speech {
        SpeakerSetup.quiet()
        ModelHub.offlineMode = true
        let models = try await AsrModels.load(from: ParakeetSetup.folder, version: .v3)
        let manager = AsrManager(config: .default, models: models)
        var state = TdtDecoderState.make(decoderLayers: 2)
        let hint = language.flatMap { Language(rawValue: String($0.prefix(2)).lowercased()) }
        let result = try await manager.transcribe(url, decoderState: &state, language: hint)
        let words = buildWordTimings(from: result.tokenTimings ?? [])
        let lines = Self.utterances(from: words.map { ($0.word, $0.startTime, $0.endTime) })
        return Speech(
            utterances: regions.isEmpty ? lines : lines.filter { line in
                regions.contains { $0.overlaps(line.start..<max(line.end, line.start + 0.01)) }
            },
            language: language)
    }

    /// The model answers in words with times; a transcript wants lines. A line ends at
    /// a sentence end, at a pause of most of a second, or when it has run long enough
    /// that attribution would be averaging two speakers.
    static func utterances(
        from words: [(text: String, start: TimeInterval, end: TimeInterval)]
    ) -> [Utterance] {
        var lines: [Utterance] = []
        var text: [String] = []
        var start: TimeInterval = 0
        var end: TimeInterval = 0

        func flush() {
            guard !text.isEmpty else { return }
            lines.append(
                Utterance(start: start, end: max(end, start + 0.01), text: text.joined(separator: " ")))
            text = []
        }

        for word in words {
            let trimmed = word.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if !text.isEmpty, word.start - end > 0.8 || word.start - start > 20 { flush() }
            if text.isEmpty { start = word.start }
            text.append(trimmed)
            end = max(end, word.end)
            if let last = trimmed.last, ".!?".contains(last), word.end - start > 1.5 { flush() }
        }
        flush()
        return lines
    }
}

/// What stands between a fresh machine and Parakeet: its model, about 480 MB, fetched
/// once into the models folder beside whisper's. Like the speaker models it is several
/// files pulled by FluidAudio from a pinned revision with a size check, and only from
/// here — transcription runs with the hub offline and can never download.
public enum ParakeetSetup {
    public static let directory = WhisperTranscriber.modelDirectory
    static var folder: URL { directory.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml") }

    /// The int8 encoder, the decoder, the joint network, the preprocessor and the
    /// vocabularies, as served on 2026-10-22.
    public static let bytes: Int64 = 483_000_000
    public static var downloadSize: String { AssetDownload.describe(bytes) }

    public static var isReady: Bool {
        AsrModels.modelsExist(at: folder, version: .v3, encoderPrecision: .int8)
    }

    /// What choosing Parakeet fetches: ffmpeg when there is none, because the mix the
    /// engine is handed is made with it, and the model.
    public static func pending() -> [WhisperSetup.Step] {
        var steps: [WhisperSetup.Step] = []
        if !FFmpegSetup.isReady { steps.append(.fetchFFmpeg) }
        if !isReady { steps.append(.fetchParakeet) }
        return steps
    }

    public static func fetch(progress: @escaping @Sendable (String) -> Void) async throws {
        SpeakerSetup.quiet()
        ModelHub.offlineMode = false
        defer { ModelHub.offlineMode = true }
        _ = try await AsrModels.download(to: folder, version: .v3, encoderPrecision: .int8) { report in
            progress("\(Int((report.fractionCompleted * 100).rounded()))%")
        }
    }
}
