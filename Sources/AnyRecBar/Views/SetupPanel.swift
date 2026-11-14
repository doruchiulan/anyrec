import AppKit
import SwiftUI
import AnyRecKit

struct SetupPanel: View {
    @Bindable var controller: RecordingController
    let open: (URL?) -> Void

    var body: some View {
        if controller.canSeeScreen {
            VStack(alignment: .leading, spacing: 12) {
                start
                advisory
                if let failure = controller.failure { Notice(failure, level: .error) }
                recent
            }
        } else {
            PermissionPanel(controller: controller)
        }
    }

    /// Two commands, not a switch and a button: which one is pressed is the whole choice,
    /// and pressing either opens the picker straight away.
    private var start: some View {
        VStack(spacing: 6) {
            Button { controller.pickAndStart() } label: {
                Label(title(video: true), systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!controller.canStart)
            .help(Wording.recordHelp(video: true))
            Button { controller.pickAndStart(video: false) } label: {
                Label(title(video: false), systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!controller.canStartAudioOnly)
            .help(Wording.recordHelp(video: false))
        }
    }

    /// "Starting…" on whichever of the two was pressed.
    private func title(video: Bool) -> String {
        controller.phase == .starting && controller.configuration.video == video
            ? "Starting…" : Wording.record(video: video)
    }

    @ViewBuilder private var advisory: some View {
        if let advisory = controller.advisory, advisory != .speakersNotSetUp {
            VStack(alignment: .leading, spacing: 4) {
                Notice(Wording.advisory(advisory))
                if advisory == .accessibilityMissing {
                    Button("Open Privacy & Security…") {
                        NSWorkspace.shared.open(Permission.accessibility.settingsURL)
                    }
                    .buttonStyle(.link).font(.callout)
                }
            }
        }
    }

    @ViewBuilder private var recent: some View {
        if !controller.library.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 8)
                ForEach(controller.library.prefix(3)) { entry in
                    MenuRow(Wording.title(of: entry), action: { open(entry.directory) }) {
                        Text(Wording.when(entry)).monospacedDigit()
                    }
                }
            }
        }
    }
}
