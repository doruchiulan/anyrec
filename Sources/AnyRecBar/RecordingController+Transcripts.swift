import AnyRecKit
import Foundation

extension RecordingController {
    var transcriptionMode: TranscriptionMode {
        get { transcriptionOptions.parallel ? .aggregator : .engine(engine) }
        set {
            engine = newValue.preferredEngine(engine)
            transcriptionOptions = newValue.options(from: transcriptionOptions)
        }
    }

    func transcriptionEngines(using mode: TranscriptionMode) -> [TranscriptionEngine] {
        mode.options(from: transcriptionOptions).engines(preferred: mode.preferredEngine(engine),
            available: Set(TranscriptionEngine.allCases.filter { readiness.of($0).isReady }))
    }

    func enableEngine(_ engine: TranscriptionEngine, enabled: Bool) {
        if enabled { transcriptionOptions.enabledEngines.insert(engine) }
        else { transcriptionOptions.enabledEngines.remove(engine) }
    }

    func canTranscribe(_ entry: LibraryEntry) -> Bool {
        acceptsProcessing && !working.contains(entry.directory)
            && (entry.transcript != nil || !entry.noSpeechDetected)
            && !TranscriptionService.tracks(in: OutputPlan(directory: entry.directory)).isEmpty
    }

    func transcribe(_ entry: LibraryEntry, using mode: TranscriptionMode) {
        guard canTranscribe(entry), !transcriptionEngines(using: mode).isEmpty else { return }
        processing.enqueue(RecordingJobs.Request(
            transcribing: entry.directory, engine: mode.preferredEngine(engine),
            options: mode.options(from: transcriptionOptions),
            summaryProvider: summarizes ? activeSummaryProvider : nil, summaryLanguage: summaryLanguage))
    }
}
