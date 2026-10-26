import SwiftUI
import AnyRecKit

struct MenuPanel: View {
    @Bindable var controller: RecordingController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch controller.phase {
            case .idle, .starting:
                SetupPanel(controller: controller, open: openLibrary)
            case .recording, .stopping:
                RecordingPanel(controller: controller)
            case .finished:
                OutcomePanel(controller: controller, open: openLibrary)
            }
            Divider()
            VStack(spacing: 0) {
                if controller.phase == .idle || controller.phase == .starting {
                    MenuRow("Open AnyRec") { openLibrary(nil) }
                }
                if controller.phase != .recording && controller.phase != .stopping {
                    MenuRow("Settings…") {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        openSettings()
                    }
                }
                MenuRow("Quit AnyRec") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 300)
        .task { await controller.refresh() }
    }

    /// The helper is clicked while another app is in front, and a window opened from it
    /// would appear behind that app unless this one is activated first.
    private func openLibrary(_ recording: URL?) {
        if let recording { controller.selection = recording }
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: LibraryWindow.id)
    }
}

/// A row that behaves like a menu item: full width, highlighted under the pointer in the
/// system's selection colour.
struct MenuRow<Trailing: View>: View {
    let title: String
    let action: () -> Void
    let trailing: Trailing
    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                trailing.foregroundStyle(hovering ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension MenuRow where Trailing == EmptyView {
    init(_ title: String, action: @escaping () -> Void) {
        self.init(title, action: action) { EmptyView() }
    }
}
