import SwiftUI
import AnyRecKit

struct ProcessingStatusView: View {
    @Bindable var controller: RecordingController
    let directory: URL
    var compact = false

    var body: some View {
        if let message = controller.processingMessage(for: directory) {
            VStack(alignment: .leading, spacing: 8) {
                if controller.working.contains(directory) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(compact ? heading : message)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .help(message)
                } else {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if controller.processing.items[directory]?.result?.issue != nil {
                        Button("Retry") { controller.processing.retry(directory) }
                    }
                }
            }
        }
    }

    private var heading: String {
        if controller.summarizing.contains(directory) { return "Writing summary…" }
        switch controller.processing.items[directory]?.stage {
        case .queued: return "Waiting to process…"
        case .merging: return "Preparing recording…"
        case .transcribing: return "Transcribing…"
        case .finished, nil: return "Processing…"
        }
    }
}

struct TranscriptPlaceholder: View {
    @Bindable var controller: RecordingController
    let entry: LibraryEntry

    var body: some View {
        VStack(spacing: 12) {
            if entry.noSpeechDetected {
                Text("No speech detected").font(.headline)
            } else {
                ProcessingStatusView(controller: controller, directory: entry.directory)
                if !controller.working.contains(entry.directory) {
                    Text("No transcript yet").font(.headline)
                    if controller.canTranscribe(entry) {
                        TranscriptAction(controller: controller, entry: entry).buttonStyle(.borderedProminent)
                    } else if TranscriptionService.tracks(in: OutputPlan(directory: entry.directory)).isEmpty {
                        Text("This recording has no available audio tracks.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
