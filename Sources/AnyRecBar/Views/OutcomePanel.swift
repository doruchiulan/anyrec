import AppKit
import SwiftUI
import AnyRecKit

struct OutcomePanel: View {
    @Bindable var controller: RecordingController
    let open: (URL?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let saved = controller.saved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                summary(saved)
                ProcessingStatusView(controller: controller, directory: saved.directory, compact: true)
            }
            if let failure = controller.failure { Notice(failure, level: .error) }
            HStack {
                Button("Open Recording") {
                    open(controller.saved?.directory)
                    controller.dismiss()
                }
                .disabled(controller.saved == nil)
                Spacer()
                Button("Done") { controller.dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func summary(_ saved: SavedRecording) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(saved.title).font(.title3).bold().lineLimit(1)
            Text([Wording.clock(saved.duration), saved.capture.summary.endedEarly]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(verdicts(saved.capture.summary), id: \.self) { Notice($0) }
            if let note = saved.note { Notice(note) }
        }
    }

    private func verdicts(_ summary: RecordingSummary) -> [String] {
        AudioTrack.allCases.compactMap { track in
            MeterScale.verdict(peak: summary.peak(for: track), for: track)
                .map { "\(track.rawValue): \($0)" }
        }
    }
}
