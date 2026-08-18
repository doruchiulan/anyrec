import AppKit
import SwiftUI

@main
struct AnyRecBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(controller: delegate.controller)
        } label: {
            MenuBarLabel(controller: delegate.controller)
        }
        /// A menu bar extra should show a menu, not a panel — except where the
        /// functionality is too complex for one, which live meters and a capture
        /// picker are.
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindow(controller: delegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = RecordingController()

    func applicationDidFinishLaunching(_: Notification) {
        Task { await controller.prepare() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.applicationShouldTerminate(sender)
    }
}

/// The menu bar itself: a symbol when idle, and the running time beside it once there
/// is one, because the panel is usually shut. The state is carried by the filled
/// symbol and the clock rather than by colour — a status item is drawn as a template,
/// so a tint here would be stripped.
struct MenuBarLabel: View {
    @Bindable var controller: RecordingController

    var body: some View {
        if controller.isRecording {
            Label(controller.clock, systemImage: "record.circle.fill")
        } else {
            Image(systemName: "record.circle")
        }
    }
}
