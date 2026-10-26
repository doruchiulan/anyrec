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

    private var start: some View {
        Button { controller.pickAndStart() } label: {
            Label(controller.phase == .starting ? "Starting…" : "Record Window…", systemImage: "record.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!controller.canStart)
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
