import AppKit
import SwiftUI

@main
struct AnyRecBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        /// The app itself: a Dock icon and this window, opened at launch. Closing the
        /// window leaves the app running — a recording and the menu bar helper outlive it.
        Window("AnyRec", id: LibraryWindow.id) {
            LibraryView(controller: delegate.controller)
        }
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(Preferences.welcomed ? .presented : .suppressed)
        .commands { AnyRecCommands(controller: delegate.controller) }

        Window("Welcome to AnyRec", id: WelcomeSheet.windowID) {
            WelcomeSheet(controller: delegate.controller)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Preferences.welcomed ? .suppressed : .presented)

        /// The helper: start a recording from anywhere, watch one, and get back to the app.
        /// Shown unless switched off in Settings › General — whether an extra is in the
        /// menu bar is the person's call, and the Dock menu reaches the same commands.
        MenuBarExtra(isInserted: Binding(
            get: { delegate.controller.showsMenuBarExtra },
            set: { delegate.controller.showsMenuBarExtra = $0 })
        ) {
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

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    /// The menu bar extra can be hidden, by the person or by the system when the menu bar
    /// is full, so the Dock menu carries what it does.
    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if controller.isRecording {
            menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "New Recording…", action: #selector(newRecording), keyEquivalent: "")
        }
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func newRecording() { controller.pickAndStart() }
    @objc private func stopRecording() { Task { await controller.stop() } }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.applicationShouldTerminate(sender)
    }
}

/// The menu bar itself: a symbol when idle, a phone while a call app holds the
/// microphone and nothing is being recorded, and the running time beside the filled
/// symbol once there is one, because the panel is usually shut. The state is carried
/// by the symbol and the clock rather than by colour — a status item is drawn as a
/// template, so a tint here would be stripped.
struct MenuBarLabel: View {
    @Bindable var controller: RecordingController

    var body: some View {
        if controller.isRecording {
            Label(controller.clock, systemImage: "record.circle.fill")
        } else if !controller.working.isEmpty {
            Image(systemName: "clock")
        } else if controller.callApp != nil {
            Image(systemName: "phone.circle.fill")
        } else {
            Image(systemName: "record.circle")
        }
    }
}
