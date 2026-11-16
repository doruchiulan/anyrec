import AnyRecKit
import Foundation

extension RecordingController {
    var transcriptionMode: TranscriptionMode {
        get { .engine(engine) }
        set { engine = newValue.preferredEngine }
    }

    func transcriptionEngines(using mode: TranscriptionMode) -> [TranscriptionEngine] {
        mode.options(from: transcriptionOptions).engines(preferred: mode.preferredEngine, available: availableEngines)
    }

    /// Engines that can run on this Mac right now: model downloaded, key saved, macOS new enough.
    var availableEngines: Set<TranscriptionEngine> {
        Set(TranscriptionEngine.allCases.filter { readiness.of($0).isReady })
    }

    /// Enabled and able to run. An engine without its model counts as off however its
    /// switch was saved: Settings shows it off, the Engine menu dims it, and review never
    /// compares against it.
    func isUsable(_ engine: TranscriptionEngine) -> Bool {
        if engine == .auto { return readiness.of(.auto).isReady }
        return transcriptionOptions.enabledEngines.contains(engine) && readiness.of(engine).isReady
    }

    /// The default for a new install, once its onboarding downloads are in:
    /// `TranscriptionOptions.localOrder`, Parakeet, then Whisper, then Apple. Left as it is
    /// when none of them can run.
    func chooseSetupDefaultEngine() {
        if let best = transcriptionOptions.setupDefault(available: availableEngines) { engine = best }
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
