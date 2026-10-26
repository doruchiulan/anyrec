import Foundation
import Testing

@testable import AnyRecBar
@testable import AnyRecKit

@Suite("Background recording processing")
@MainActor
struct RecordingJobsTests {
    @Test("Done frees the recorder while two recordings retain their own progress and engine")
    func backToBack() async throws {
        let first = request("first", engine: .whisper)
        let second = request("second", engine: .parakeet)
        let worker = HeldWorker()
        let jobs = RecordingJobs { request, progress in await worker.run(request, progress: progress) }
        let controller = RecordingController(processing: jobs, completedSetup: true)
        controller.recordingSaved(try saved(first), configuration: configuration(first))
        try await until { jobs.items[first.directory]?.stage == .transcribing }
        #expect(controller.canStart)
        controller.dismiss()
        #expect(controller.phase == .idle && controller.saved == nil)
        #expect(controller.working == [first.directory])

        controller.recordingSaved(try saved(second), configuration: configuration(second))
        #expect(controller.canStart)
        #expect(jobs.items[second.directory]?.stage == .queued)
        #expect(controller.processingMessage(for: first.directory) == "Processing first")
        #expect(controller.processingMessage(for: second.directory) == "Waiting to process…")
        await worker.release(first.directory)
        try await until { jobs.items[second.directory]?.stage == .transcribing }
        await worker.lateProgress(first.directory)
        #expect(controller.saved?.directory == second.directory)
        #expect(controller.phase == .finished && controller.canStart)
        #expect(controller.working == [second.directory])
        await worker.release(second.directory)
        await jobs.waitUntilIdle()
        #expect(controller.working.isEmpty)
        #expect(controller.saved?.directory == second.directory)
        #expect(await worker.engines == [.whisper, .parakeet])
        #expect(jobs.items[first.directory]?.stage == .finished)
        #expect(jobs.items[first.directory]?.message != "Late progress")
    }

    @Test("duplicates are ignored and a failed transcript can be retried without an old callback changing it")
    func retry() async throws {
        let request = request("retry", engine: .whisper)
        let worker = HeldWorker(failingOnce: request.directory)
        let jobs = RecordingJobs { request, progress in await worker.run(request, progress: progress) }
        jobs.enqueue(request)
        jobs.enqueue(request)
        try await until { jobs.items[request.directory]?.stage == .transcribing }
        await worker.release(request.directory)
        await jobs.waitUntilIdle()
        #expect(jobs.items[request.directory]?.result?.issue?.contains("Test failure") == true)
        #expect(await worker.engines.count == 1)
        jobs.retry(request.directory)
        await worker.lateProgress(request.directory)
        await jobs.waitUntilIdle()
        #expect(jobs.items[request.directory]?.result?.issue == nil)
        #expect(jobs.items[request.directory]?.stage == .finished)
        #expect(await worker.engines.count == 2)
    }

    @Test("waiting for processing includes jobs queued behind the active one")
    func waitForAll() async throws {
        let first = request("one", engine: .whisper)
        let second = request("two", engine: .parakeet)
        let worker = HeldWorker()
        let jobs = RecordingJobs { request, progress in await worker.run(request, progress: progress) }
        jobs.enqueue(first)
        jobs.enqueue(second)
        var finished = false
        let wait = Task { await jobs.waitUntilIdle(); finished = true }
        try await until { jobs.items[first.directory]?.stage == .transcribing }
        #expect(!finished)
        await worker.release(first.directory)
        try await until { jobs.items[second.directory]?.stage == .transcribing }
        #expect(!finished)
        await worker.release(second.directory)
        await wait.value
        #expect(finished && jobs.working.isEmpty)
    }

    private func request(_ name: String, engine: TranscriptionEngine) -> RecordingJobs.Request {
        let summary = RecordingSummary(
            plan: OutputPlan(directory: URL(fileURLWithPath: "/tmp/anyrec-jobs-\(UUID())/\(name)")),
            screenFrames: 30, systemAudioSamples: 10, microphoneSamples: 10, droppedSamples: 0,
            systemAudioPeak: -10, microphonePeak: -10, endedEarly: nil)
        return RecordingJobs.Request(capture: CapturedRecording(summary: summary), merge: false, engine: engine)
    }

    @Test("existing recordings use a transcription-only request with the engine selected for that recording")
    func existingRecording() async throws {
        let worker = HeldWorker()
        let jobs = RecordingJobs { request, progress in await worker.run(request, progress: progress) }
        let directory = URL(fileURLWithPath: "/tmp/anyrec-existing-\(UUID())")
        let request = RecordingJobs.Request(transcribing: directory, engine: .whisper)
        jobs.enqueue(request)
        try await until { jobs.items[request.directory]?.stage == .transcribing }
        #expect(request.capture == nil && !request.merge)
        #expect(jobs.items[request.directory]?.request.engine == .whisper)
        await worker.release(request.directory)
        await jobs.waitUntilIdle()
        #expect(jobs.items[request.directory]?.result?.recording == nil)
        jobs.enqueue(RecordingJobs.Request(transcribing: directory, engine: .parakeet))
        await jobs.waitUntilIdle()
        #expect(await worker.engines == [.whisper, .parakeet])
    }

    @Test("a failed regeneration leaves the previous transcript selected")
    func failedRegeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-regenerate-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = Transcript(utterances: [Utterance(start: 0, end: 1, text: "Keep this", speaker: .me)],
                                    language: "en", engine: "parakeet")
        let previous = try TranscriptStore.publish(transcript, voices: nil, in: directory)
        let jobs = RecordingJobs()
        let request = RecordingJobs.Request(transcribing: directory, engine: .whisper)
        jobs.enqueue(request)
        await jobs.waitUntilIdle()
        #expect(jobs.items[request.directory]?.result?.issue != nil)
        #expect(TranscriptStore.activeTranscript(in: directory) == previous[2])
    }

    private func saved(_ request: RecordingJobs.Request) throws -> SavedRecording {
        SavedRecording(capture: try #require(request.capture), title: request.directory.lastPathComponent, duration: 1, note: nil)
    }

    private func configuration(_ request: RecordingJobs.Request) -> RecordingConfiguration {
        var configuration = RecordingConfiguration()
        configuration.transcribe = request.engine
        configuration.mux = request.merge
        return configuration
    }

    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }
}

private actor HeldWorker {
    private var failingOnce: URL?
    private var callbacks: [URL: @Sendable (RecordingJobs.Update) -> Void] = [:]
    private var continuations: [URL: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<URL> = []
    private(set) var engines: [TranscriptionEngine?] = []

    init(failingOnce: URL? = nil) { self.failingOnce = failingOnce }

    func run(_ request: RecordingJobs.Request,
             progress: @escaping @Sendable (RecordingJobs.Update) -> Void) async -> RecordingJobs.Result {
        let directory = request.directory
        engines.append(request.engine)
        callbacks[directory] = progress
        progress(RecordingJobs.Update(stage: .transcribing, message: "Processing \(directory.lastPathComponent)"))
        if !released.contains(directory) {
            await withCheckedContinuation { continuations[directory] = $0 }
        }
        let transcript: TranscriptOutcome = failingOnce == directory
            ? .failed(reason: "Test failure", remedy: nil) : .nothingHeard
        failingOnce = nil
        return RecordingJobs.Result(
            recording: request.capture.map { RecordingOutcome(summary: $0.summary, merge: .notRequested) },
            transcript: transcript)
    }

    func release(_ directory: URL) {
        released.insert(directory)
        continuations.removeValue(forKey: directory)?.resume()
    }

    func lateProgress(_ directory: URL) {
        callbacks[directory]?(RecordingJobs.Update(stage: .transcribing, message: "Late progress"))
    }
}
