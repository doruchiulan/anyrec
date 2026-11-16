import AppKit
import SwiftUI
import AnyRecKit

/// After a recording: what it was, and what is happening to it now, as a checklist. No
/// level warnings: nothing can be done about clipping after the fact, and the levels can be
/// measured again from the tracks. New Recording, not Done: processing goes on in the
/// background whatever is pressed, and "Done" read as "finished" or "wait for it".
struct OutcomePanel: View {
    @Bindable var controller: RecordingController
    let open: (URL?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let saved = controller.saved {
                summary(saved)
                ProcessingChecklist(controller: controller, saved: saved)
            }
            if let failure = controller.failure { Notice(failure, level: .error) }
            HStack {
                Button("Open Recording") {
                    open(controller.saved?.directory)
                    controller.dismiss()
                }
                .disabled(controller.saved == nil)
                Spacer()
                Button("New Recording") { controller.dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Back to recording. Anything still processing carries on in the background.")
            }
        }
    }

    private func summary(_ saved: SavedRecording) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(saved.title).font(.headline).lineLimit(2)
            Text([Wording.clock(saved.duration), saved.capture.summary.endedEarly]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            /// The one note worth showing: a permission the owner can still grant.
            if let note = saved.note { Notice(note) }
        }
    }
}

/// Each step after saving, with a check, a spinner, a dot for waiting, or a warning with
/// Retry when it failed.
private struct ProcessingChecklist: View {
    @Bindable var controller: RecordingController
    let saved: SavedRecording

    var body: some View {
        let item = controller.processing.items[saved.directory]
        let checklist = ProcessingSteps(
            merges: item?.request.merge ?? false, transcribes: item?.request.engine != nil,
            summarises: item?.request.summary != nil, stage: item?.stage, result: item?.result)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(checklist.steps) { step in
                HStack(spacing: 8) {
                    icon(step.state).frame(width: 16)
                    Text(step.title)
                        .foregroundStyle(step.state == .waiting ? .secondary : .primary)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
                .accessibilityValue(Wording.stepState(step.state))
            }
            if let issue = item?.result?.issue {
                Text(issue).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Retry") { controller.processing.retry(saved.directory) }.controlSize(.small)
            } else if checklist.working {
                Text("Continues in the background.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func icon(_ state: ProcessingSteps.State) -> some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .running: ProgressView().controlSize(.small)
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
