#if ANYREC_WEBSITE_DEMO
import SwiftUI

@main
struct WebsiteDemoApp: App {
    @NSApplicationDelegateAdaptor(DemoScenes.self) private var scenes

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandMenu("Scenes") {
                    Button("Call Reminder") { scenes.showReminder() }.keyboardShortcut("1")
                    Button("Recording Panel") { scenes.record(true) }.keyboardShortcut("2")
                    Button("Transcript") { scenes.stop() }.keyboardShortcut("3")
                }
            }
    }
}

@MainActor
final class DemoScenes: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var fixture: DemoTranscript?
    private let call = DemoCallWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    private lazy var reminder = ReminderPanel(appName: "Slack", record: { [weak self] in self?.record($0) },
                                              dismiss: { [weak self] in self?.hideReminder() })
    private lazy var status = DemoStatusItem(stop: { [weak self] in self?.stop() },
                                            open: { [weak self] in self?.showReview() },
                                            idle: { [weak self] in self?.showReminder() })
    private var review: NSWindow?

    func applicationDidFinishLaunching(_: Notification) {
        do {
            guard Bundle.main.bundleIdentifier == "com.doruchiulan.anyrec.website-demo" else {
                throw CocoaError(.fileReadUnknown)
            }
            fixture = try DemoTranscript()
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }
        let host = NSHostingView(rootView: DemoCall().frame(width: 500))
        call.title = "Sketch review"
        call.isOpaque = false
        call.backgroundColor = .clear
        call.isMovableByWindowBackground = true
        call.contentView = host
        call.setContentSize(host.fittingSize)
        call.center()
        call.delegate = self
        showReminder()
    }

    func showReminder() {
        status.reset()
        review?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        call.makeKeyAndOrderFront(nil)
        if reminder.parent == nil { call.addChildWindow(reminder, ordered: .above) }
        positionReminder()
        reminder.orderFrontRegardless()
    }

    func windowDidMove(_: Notification) {
        if reminder.isVisible { positionReminder() }
    }

    private func positionReminder() {
        if let frame = CallReminderPlacement.frame(above: call.frame, size: CallReminderView.size,
                                                   screens: NSScreen.screens.map(\.visibleFrame)) {
            reminder.setFrame(frame, display: true)
        }
    }

    private func hideReminder() {
        reminder.parent?.removeChildWindow(reminder)
        reminder.orderOut(nil)
    }

    func record(_ video: Bool) {
        hideReminder()
        review?.orderOut(nil)
        call.orderFrontRegardless()
        status.record(video)
    }

    func stop() {
        status.reset()
        showReview()
    }

    private func showReview() {
        guard let fixture else { return }
        hideReminder()
        call.orderOut(nil)
        if review == nil {
            let host = NSHostingController(rootView: DemoReview(fixture: fixture).frame(width: 520, height: 300))
            let window = NSWindow(contentViewController: host)
            window.title = "AnyRec Website Demo"
            window.isReleasedWhenClosed = false
            window.center()
            review = window
        }
        NSApp.activate(ignoringOtherApps: true)
        review?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_: Notification) {
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }
}
private final class DemoCallWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
#endif
