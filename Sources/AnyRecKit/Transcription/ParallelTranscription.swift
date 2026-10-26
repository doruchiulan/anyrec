import Foundation

public struct TranscriptionCandidates: Sendable {
    public let primary: TranscriptionService.Transcribed
    public let transcripts: [Transcript]
    public let failures: [String]
}

enum ParallelTranscription {
    struct Result: Sendable {
        let engine: TranscriptionEngine
        let transcript: Transcript?
        let failure: String?
    }

    static func collect(
        engines: [TranscriptionEngine],
        completed: @escaping @Sendable (Result, Int) -> Void = { _, _ in },
        recognize: @escaping @Sendable (TranscriptionEngine) async throws -> Transcript
    ) async -> [Result] {
        await withTaskGroup(of: Result.self) { group in
            for engine in engines {
                group.addTask {
                    do { return Result(engine: engine, transcript: try await recognize(engine), failure: nil) }
                    catch { return Result(engine: engine, transcript: nil, failure: "\(engine.rawValue): \(error)") }
                }
            }
            var results: [Result] = []
            for await result in group {
                results.append(result)
                completed(result, results.count)
            }
            return engines.compactMap { engine in results.first { $0.engine == engine } }
        }
    }
}

extension TranscriptionService {
    public static func candidates(
        _ job: Job, engines: [TranscriptionEngine], identifySpeakers: Bool = true, progress: @escaping @Sendable (String) -> Void
    ) async throws -> TranscriptionCandidates {
        guard !engines.isEmpty else {
            throw TranscriptionError.engineFailed(engine: "transcription", log: "Enable an available engine in Settings › Transcription.")
        }
        let prepared = try prepared(job, progress: progress)
        defer { try? FileManager.default.removeItem(at: prepared.scratch) }
        progress("Transcribing with " + engines.map(\.rawValue).joined(separator: ", ") + "…")
        let results = await ParallelTranscription.collect(engines: engines, completed: { result, count in
            progress("\(result.engine.rawValue) \(result.failure == nil ? "finished" : "failed") — \(count) of \(engines.count) engines finished…")
        }) { engine in
            var candidate = job
            candidate.engine = engine
            return try await recognize(candidate, source: prepared.audio, progress: { _ in })
        }
        try Task.checkCancellation()
        let transcripts = results.compactMap(\.transcript)
        let failures = results.compactMap(\.failure)
        guard let primary = transcripts.first(where: { !$0.isEmpty }) ?? transcripts.first,
              !primary.isEmpty || failures.isEmpty else {
            throw TranscriptionError.engineFailed(engine: "transcription", log: failures.joined(separator: "\n"))
        }
        let (lines, voices) = identifySpeakers
            ? await separate(primary, in: prepared.audio, useDiarization: job.diarize, progress: progress)
            : (primary.utterances, nil)
        let attributed = Transcript(utterances: lines, language: primary.language, engine: primary.engine,
                                   notes: primary.notes + failures.map { "Engine unavailable: \($0)" })
        return TranscriptionCandidates(primary: Transcribed(transcript: attributed, voices: voices),
                                       transcripts: transcripts, failures: failures)
    }
}
