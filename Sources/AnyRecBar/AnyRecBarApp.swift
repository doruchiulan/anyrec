import AppKit
import SwiftUI

@main
struct AnyRecBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        /// The app itself: a Dock icon and this window. It is not opened at launch — a launch
        /// by hand drops the menu bar panel open instead, and one at login shows nothing —
        /// and opens from the Dock icon, the helper's Open AnyRec, or the Window menu.
        /// Closing it leaves the app running: a recording and the menu bar helper outlive it.
        Window("AnyRec", id: LibraryWindow.id) {
            LibraryView(controller: delegate.controller)
        }
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(.suppressed)
        /// macOS reopens windows that were open at quit, which would bring the library back
        /// at the next launch whatever the line above says.
        .restorationBehavior(.disabled)
        .commands { AnyRecCommands(controller: delegate.controller) }

        Window("Welcome to AnyRec", id: WelcomeSheet.windowID) {
            WelcomeSheet(controller: delegate.controller)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Preferences.welcomed ? .suppressed : .presented)

        Settings {
            SettingsWindow(controller: delegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = RecordingController()
    /// The helper: start a recording from anywhere, watch one, and get back to the app.
    /// Shown unless switched off in Settings › General — whether an extra is in the menu
    /// bar is the person's call, and the Dock menu reaches the same commands.
    private var statusItem: StatusItem?

    func applicationDidFinishLaunching(_: Notification) {
        /// Read first: the launch event is only current while this runs.
        let atLogin = Self.launchedAtLogin
        let statusItem = StatusItem(controller: controller)
        self.statusItem = statusItem
        controller.willPresentPicker = { [weak statusItem] in statusItem?.close() }
        Task { await controller.prepare() }

        /// Started by hand, the app shows itself where people work with it — the menu bar
        /// panel, or the library when there is no menu bar item to hang it from. Started at
        /// login it stays quiet, and before setup the welcome window is the whole launch.
        guard controller.completedSetup, !atLogin else { return }
        statusItem.whenPlaced { [weak self] placed in
            guard let self else { return }
            if !(placed && statusItem.open()) { DispatchQueue.main.async { self.openLibrary() } }
        }
    }

    /// A login item is launched with an open-application event saying so, which is what
    /// tells it apart from a double-click, `open` or the Dock.
    private static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication
        else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private func openLibrary() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.openLibrary?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    /// The library is not opened at launch, so a click on the Dock icon with nothing on
    /// screen is the person asking for it. The menu bar panel does not count as something
    /// on screen: it closes, as it would on any other click outside it.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        let onlyPanel = statusItem?.isPanelOpen == true
            && !NSApplication.shared.windows.contains { $0.isVisible && $0.canBecomeMain }
        statusItem?.close()
        guard !hasVisibleWindows || onlyPanel, let open = controller.openLibrary else { return true }
        open()
        return false
    }

    /// The menu bar extra can be hidden, by the person or by the system when the menu bar
    /// is full, so the Dock menu carries what it does.
    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if controller.isRecording {
            menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: Wording.newRecording(video: true), action: #selector(newRecording), keyEquivalent: "")
            menu.addItem(withTitle: Wording.newRecording(video: false), action: #selector(newAudioRecording), keyEquivalent: "")
        }
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func newRecording() { controller.pickAndStart() }
    @objc private func newAudioRecording() { controller.pickAndStart(video: false) }
    @objc private func stopRecording() { Task { await controller.stop() } }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.applicationShouldTerminate(sender)
    }
}
