import AVFoundation
import CoreML
import Darwin
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

    private static var encoderComputeUnits: MLComputeUnits? {
        #if arch(x86_64)
        var translated: Int32 = 0
        var size = MemoryLayout.size(ofValue: translated)
        let status = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
        if status == 0 { return translated == 0 ? .cpuAndGPU : nil }
        // Native Intel can omit the Rosetta sysctl.
        return errno == ENOENT ? .cpuAndGPU : nil
        #else
        return nil
        #endif
    }

    /// How many chunks FluidAudio transcribes at once. Each is a synchronous CoreML
    /// prediction on a thread of Swift's shared pool. On Intel, with no Neural Engine, each
    /// runs on the CPU, which CoreML already spreads over every core, so FluidAudio's four
    /// at once only fought over the same cores and held more of the pool for minutes. Apple
    /// silicon keeps FluidAudio's default: there one at a time made Parakeet slower.
    static var chunkConcurrency: Int {
        #if arch(x86_64)
        return 1
        #else
        return ASRConfig.default.parallelChunkConcurrency
        #endif
    }

    /// `regions` are not handed to the model — it reads the file whole, and a TDT model
    /// does not invent over silence the way whisper does — but a line it places where
    /// nobody was speaking is dropped, since that is the only kind it gets wrong there.
    public func speech(
        of url: URL, in regions: [Range<TimeInterval>], language: String?
    ) async throws -> Speech {
        SpeakerSetup.quiet()
        ModelNetwork.offline()
        let models = try await AsrModels.load(
            from: ParakeetSetup.folder, version: .v3,
            encoderComputeUnits: Self.encoderComputeUnits)
        let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: Self.chunkConcurrency), models: models)
        var state = TdtDecoderState.make(decoderLayers: 2)
        let hint = language.flatMap { Language(rawValue: String($0.prefix(2)).lowercased()) }
        let result = try await manager.transcribe(url, decoderState: &state, language: hint)
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            Speech.Word(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
        return Speech(utterances: Self.lines(from: words, in: regions), language: language, words: words)
    }

    /// The lines, keeping only those that overlap speech. Whole lines, never single words:
    /// a word that falls in a gap between regions still belongs to its sentence.
    static func lines(
        from words: [Speech.Word], cuts: Set<Int> = [], in regions: [Range<TimeInterval>]
    ) -> [Utterance] {
        utterances(from: words, cuts: cuts).filter { line in
            regions.isEmpty || regions.contains { $0.overlaps(line.start..<max(line.end, line.start + 0.01)) }
        }
    }

    /// The model answers in words with times; a transcript wants lines. A line ends at
    /// a sentence end, at a pause of most of a second, or when it has run long enough
    /// that attribution would be averaging two speakers. `cuts` are word indices where a
    /// line must start whatever the punctuation: where the call started or stopped talking
    /// (`CallTurns`), because turns often flip with no pause and no full stop.
    static func utterances(from words: [Speech.Word], cuts: Set<Int> = []) -> [Utterance] {
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

        for (index, word) in words.enumerated() {
            let trimmed = word.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if !text.isEmpty, cuts.contains(index) || word.start - end > 0.8 || word.start - start > 20 { flush() }
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
        _ = try await ModelNetwork.downloading {
            try await AsrModels.download(to: folder, version: .v3, encoderPrecision: .int8) { report in
                progress("\(Int((report.fractionCompleted * 100).rounded()))%")
            }
        }
    }
}
