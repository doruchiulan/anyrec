import SwiftUI
import AnyRecKit

/// What drops down from the menu bar: the setup panel, the live recording, or what the
/// last one left behind.
struct MenuPanel: View {
    @Bindable var controller: RecordingController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .task { await controller.refresh() }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .idle, .starting:
            SetupPanel(controller: controller)
        case .recording, .stopping:
            RecordingPanel(controller: controller)
        case .transcribing, .finished:
            OutcomePanel(controller: controller)
        }
    }

    private var footer: some View {
        HStack {
            Text(controller.configuration.outputRoot)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button("Settings") {
                /// `LSUIElement` means no Dock icon and nothing to bring forward, so
                /// the window opens behind everything unless the app is activated.
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            }
            .buttonStyle(.link)
            .font(.caption)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}
