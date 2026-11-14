import AnyRecKit
import Foundation

extension RecordingController {
    var transcriptionMode: TranscriptionMode {
        get { .engine(engine) }
        set { engine = newValue.preferredEngine }
    }

    func transcriptionEngines(using mode: TranscriptionMode) -> [TranscriptionEngine] {
        mode.options(from: transcriptionOptions).engines(preferred: mode.preferredEngine,
            available: Set(TranscriptionEngine.allCases.filter { readiness.of($0).isReady }))
    }

    /// What a summary after a transcript is asked for with, when one is.
    var summaryRequest: SummaryRequest? {
        guard summarizes, let provider = activeSummaryProvider else { return nil }
        return SummaryRequest(provider: provider, language: summaryLanguage)
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
            transcribing: entry.directory, engine: mode.preferredEngine,
            options: mode.options(from: transcriptionOptions), summary: summaryRequest))
    }
}
