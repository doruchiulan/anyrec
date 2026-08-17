import SwiftUI
import AnyRecKit

/// What drops down from the menu bar: the setup panel, the live recording, or what the
/// last one left behind.
struct MenuPanel: View {
    @Bindable var controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .task { await controller.refreshCatalogue() }
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
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}
