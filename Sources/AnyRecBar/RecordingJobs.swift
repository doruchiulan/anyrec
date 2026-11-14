import AnyRecKit
import Foundation
import Observation

struct SavedRecording {
    let capture: CapturedRecording
    let title: String
    let duration: TimeInterval
    let note: String?

    var directory: URL { capture.summary.plan.directory }
}

@MainActor
@Observable
final class RecordingJobs {
    struct Request: Sendable {
        let capture: CapturedRecording?
        let plan: OutputPlan
        let merge: Bool
        let engine: TranscriptionEngine?
        let options: TranscriptionOptions?
        /// The summary the Kit's pass writes after the transcript, when one is wanted.
        var summary: SummaryRequest?

        var directory: URL { plan.directory }

        init(capture: CapturedRecording, merge: Bool, engine: TranscriptionEngine?,
             options: TranscriptionOptions? = nil, summary: SummaryRequest? = nil) {
            self.capture = capture
            plan = capture.summary.plan
            self.merge = merge
            self.engine = engine
            self.options = options
            self.summary = summary
        }

        init(transcribing directory: URL, engine: TranscriptionEngine,
             options: TranscriptionOptions? = nil, summary: SummaryRequest? = nil) {
            capture = nil
            plan = OutputPlan(directory: directory)
            merge = false
            self.engine = engine
            self.options = options
            self.summary = summary
        }
    }

    struct Result: Sendable {
        let recording: RecordingOutcome?
        let transcript: TranscriptOutcome?

        init(recording: RecordingOutcome? = nil, transcript: TranscriptOutcome?) {
            self.recording = recording
            self.transcript = transcript
        }

        var issue: String? {
            if case .failed = transcript { return transcript.map(Wording.transcript) }
            guard let recording else { return nil }
            switch recording.merge {
            case .failed, .ffmpegMissing: return Wording.merge(recording.merge)
            case .merged, .notRequested: return nil
            }
        }
    }

    enum Stage: Int, Sendable { case queued, merging, transcribing, finished }

    struct Update: Sendable {
        let stage: Stage
        let message: String
    }

    struct Item {
        let id: UUID
        let request: Request
        var stage: Stage = .queued
        var message = "Waiting to process…"
        var result: Result?

        var isWorking: Bool { stage != .finished }
    }

    typealias Operation = @Sendable (Request, @escaping @Sendable (Update) -> Void) async -> Result
    private(set) var items: [URL: Item] = [:]
    @ObservationIgnored var onCompletion: ((Request, Result) async -> Void)?
    @ObservationIgnored private var pending: [URL] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let operation: Operation

    init(operation: @escaping Operation = { request, progress in
        await RecordingJobs.process(request, progress: progress)
    }) {
        self.operation = operation
    }

    var working: Set<URL> { Set(items.filter { $0.value.isWorking }.keys) }

    func enqueue(_ request: Request) {
        guard items[request.directory]?.isWorking != true else { return }
        items[request.directory] = Item(id: UUID(), request: request)
        pending.append(request.directory)
        if worker == nil { worker = Task { await drain() } }
    }

    func retry(_ directory: URL) {
        guard let item = items[directory], item.result?.issue != nil else { return }
        enqueue(item.request)
    }

    func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    private func drain() async {
        while !pending.isEmpty {
            let directory = pending.removeFirst()
            guard let item = items[directory] else { continue }
            let operation = operation
            let report: @Sendable (Update) -> Void = { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.update(update, directory: directory, id: item.id)
                }
            }
            let result = await Task.detached(priority: .utility) {
                await operation(item.request, report)
            }.value
            items[directory]?.result = result
            items[directory]?.stage = .finished
            await onCompletion?(item.request, result)
        }
        worker = nil
    }

    private func update(_ update: Update, directory: URL, id: UUID) {
        guard let item = items[directory], item.id == id, item.isWorking,
            update.stage.rawValue >= item.stage.rawValue else { return }
        items[directory]?.stage = update.stage
        items[directory]?.message = update.message
    }

    /// The mix is decided first, once, and kept beside the tracks; then the merge and the
    /// transcript run side by side, since neither needs what the other makes. Capture has
    /// already been released by the time a request is queued.
    nonisolated private static func process(
        _ request: Request, progress: @escaping @Sendable (Update) -> Void
    ) async -> Result {
        guard let capture = request.capture else {
            guard let engine = request.engine else { return Result(transcript: nil) }
            progress(Update(stage: .transcribing, message: "Transcribing…"))
            return Result(transcript: await transcribe(request, engine: engine, progress: progress))
        }
        progress(Update(stage: .merging, message: "Preparing the recording…"))
        if (request.merge || request.engine != nil), let ffmpeg = Muxer.ffmpegPath() {
            _ = await Task.detached(priority: .utility) { MixPlan.decided(for: request.plan, using: ffmpeg) }.value
        }
        async let merged = capture.merged(enabled: request.merge)
        guard let engine = request.engine else { return Result(recording: await merged, transcript: nil) }
        progress(Update(stage: .transcribing, message: "Transcribing…"))
        let transcript = await transcribe(request, engine: engine, progress: progress)
        return Result(recording: await merged, transcript: transcript)
    }

    nonisolated private static func transcribe(
        _ request: Request, engine: TranscriptionEngine, progress: @escaping @Sendable (Update) -> Void
    ) async -> TranscriptOutcome {
        await TranscriptPass.run(request.plan, engine: engine, options: request.options, summary: request.summary) {
            progress(Update(stage: .transcribing, message: $0))
        }
    }
}
