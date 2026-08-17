import AppKit
import SwiftUI
import AnyRecKit

/// What the last recording left behind: how long it ran, where it went, how the merge
/// went, and — when one was asked for — the transcript.
struct OutcomePanel: View {
    @Bindable var controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let outcome = controller.outcome {
                summary(outcome)
            }
            if let failure = controller.failure {
                Notice(failure, level: .error)
            }
            transcript
            buttons
        }
    }

    private func summary(_ outcome: RecordingOutcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title(outcome), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            Text(outcome.summary.plan.directory.lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(Wording.merge(outcome.merge))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(verdicts(outcome.summary), id: \.self) { verdict in
                Text(verdict).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// A stream that stopped because its window closed has ended the recording, not
    /// failed it — so it is said here rather than thrown.
    private func title(_ outcome: RecordingOutcome) -> String {
        guard let ended = outcome.summary.endedEarly else { return "Recorded" }
        return "Recorded — \(ended)"
    }

    private func verdicts(_ summary: RecordingSummary) -> [String] {
        AudioTrack.allCases.compactMap { track in
            MeterScale.verdict(peak: summary.peak(for: track), for: track)
                .map { "\(track.rawValue): \($0)" }
        }
    }

    @ViewBuilder private var transcript: some View {
        if controller.phase == .transcribing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(controller.progress ?? "Transcribing…")
                    .font(.caption)
                    .lineLimit(1)
            }
        } else if let outcome = controller.transcript {
            Text(Wording.transcript(outcome))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let note = controller.note {
            Notice(note)
        }
    }

    private var buttons: some View {
        HStack {
            Button("Show in Finder") { reveal() }
                .disabled(controller.outcome == nil)
            Spacer()
            Button("Done") { controller.dismiss() }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.phase != .finished)
        }
    }

    private func reveal() {
        guard let directory = controller.outcome?.summary.plan.directory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}
