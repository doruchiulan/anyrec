import AnyRecKit
import SwiftUI

struct TranscriptAction: View {
    @Bindable var controller: RecordingController
    let entry: LibraryEntry

    var body: some View {
        if entry.transcript != nil || !entry.noSpeechDetected {
            Button(entry.transcript == nil ? "Generate Transcript…" : "Regenerate Transcript…") {
                controller.transcriptRequest = entry
            }
            .disabled(!controller.canTranscribe(entry))
        }
    }
}

struct TranscriptGeneration: View {
    @Bindable var controller: RecordingController
    let entry: LibraryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var mode: TranscriptionMode

    init(controller: RecordingController, entry: LibraryEntry) {
        self.controller = controller
        self.entry = entry
        let previous = entry.transcript.flatMap(Transcript.read).flatMap { TranscriptionEngine(rawValue: $0.engine) }
        let preferred = controller.transcriptionOptions.parallel ? TranscriptionMode.aggregator : .engine(previous ?? controller.engine)
        _mode = State(initialValue: !controller.transcriptionEngines(using: preferred).isEmpty ? preferred : .engine(.auto))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.transcript == nil ? "Generate Transcript" : "Regenerate Transcript").font(.title2.bold())
            Text(Wording.title(of: entry)).foregroundStyle(.secondary).lineLimit(2)
            enginePicker
            Text(description)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(entry.transcript == nil ? "Generate" : "Regenerate") {
                    controller.transcribe(entry, using: mode)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!controller.canTranscribe(entry) || controller.transcriptionEngines(using: mode).isEmpty)
            }
        }
        .padding(24).frame(width: 420)
    }

    private var enginePicker: some View {
        HStack {
            Picker("Engine", selection: $mode) {
                ForEach(TranscriptionMode.allCases, id: \.self) { choice in
                    Text(choice.name).tag(choice)
                        .selectionDisabled(controller.transcriptionEngines(using: choice).isEmpty)
                }
            }
            if case .engine(let engine) = mode, engine == .parakeet || engine == .whisper {
                EngineInfo(engine: engine)
            }
        }
    }

    private var description: String {
        let engines = controller.transcriptionEngines(using: mode)
        guard !engines.isEmpty else { return "Enable an available engine in Settings › Transcription." }
        let summary = controller.summarizes ? controller.activeSummaryProvider : nil
        return [mode.description(engines: engines, review: controller.transcriptionOptions.review),
                TranscriptionMode.textProcessing(options: controller.transcriptionOptions, summary: summary)]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
