import Foundation
import Testing
@testable import AnyRecKit

@Suite("Transcription selection and concurrency")
struct TranscriptionOptionsTests {
    @Test("defaults use one local engine and disable review and uploads")
    func defaults() {
        let options = TranscriptionOptions()
        #expect(!options.parallel && !options.review)
        #expect(!options.enabledEngines.contains(.openai))
        #expect(options.engines(preferred: .auto, available: Set(TranscriptionEngine.allCases)) == [.parakeet])
    }

    @Test("disabled and unavailable engines never run; single Automatic never uploads")
    func enabled() throws {
        var options = TranscriptionOptions()
        options.enabledEngines = [.whisper, .openai]
        options.aggregatorEngines = [.whisper, .openai]
        let available: Set<TranscriptionEngine> = [.parakeet, .whisper, .openai]
        #expect(options.engines(preferred: .auto, available: available) == [.whisper])
        #expect(options.engines(preferred: .parakeet, available: available).isEmpty)
        #expect(options.engines(preferred: .auto, available: [.openai]).isEmpty)
        options.parallel = true
        options.review = true
        options.reviewProvider = .codex
        #expect(options.engines(preferred: .whisper, available: available) == [.whisper, .openai])
        #expect(options.engines(preferred: .auto, available: [.parakeet]).isEmpty)
        #expect(try JSONDecoder().decode(TranscriptionOptions.self, from: JSONEncoder().encode(options)) == options)
    }

    @Test("engines overlap, retain preferred order and isolate a failed engine")
    func parallel() async throws {
        let gate = StartGate()
        let engines: [TranscriptionEngine] = [.whisper, .parakeet, .apple]
        let results = await ParallelTranscription.collect(engines: engines) { engine in
            await gate.arrive(engine)
            let deadline = Date().addingTimeInterval(2)
            while await gate.count < 3 {
                guard Date() < deadline else { throw TestFailure.didNotOverlap }
                try await Task.sleep(for: .milliseconds(1))
            }
            if engine == .apple { throw TestFailure.unsupported }
            return Transcript(utterances: [Utterance(start: 0, end: 1, text: "Hello")], language: "en", engine: engine.rawValue)
        }
        #expect(results.map(\.engine) == engines)
        #expect(results.prefix(2).allSatisfy { $0.transcript != nil })
        #expect(results.last?.failure?.contains("unsupported") == true)
        #expect(await gate.count == 3)
    }

    private enum TestFailure: Error { case didNotOverlap, unsupported }
    private actor StartGate {
        var engines = Set<TranscriptionEngine>()
        var count: Int { engines.count }
        func arrive(_ engine: TranscriptionEngine) { engines.insert(engine) }
    }
}
