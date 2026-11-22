import AnyRecKit
import AppKit
import SwiftUI

@MainActor
final class CallReminder {
    /// The call window, and whether to keep its picture: the banner offers Record and
    /// Audio Only side by side.
    private let onRecord: (CaptureChoice?, Bool) -> Void
    private let onChooseWindow: (Bool) -> Void
    /// Automatic recording: the call window, found and checked, ready to capture.
    private let onFound: (CaptureChoice) -> Void
    /// The started notification's Stop button.
    private let onStop: () -> Void
    private var task: Task<Void, Never>?
    private var panel: NSPanel?
    private var generation = UUID()
    private var anchor: CallWindowAnchor?
    private var window: MuteButton.Window?
    private lazy var notifier = CallNotifier(
        onRecord: { [weak self] video in self?.chooseWindow(video: video) },
        onStop: { [weak self] in self?.onStop() })

    init(onRecord: @escaping (CaptureChoice?, Bool) -> Void, onChooseWindow: @escaping (Bool) -> Void,
         onFound: @escaping (CaptureChoice) -> Void, onStop: @escaping () -> Void) {
        self.onRecord = onRecord
        self.onChooseWindow = onChooseWindow
        self.onFound = onFound
        self.onStop = onStop
    }

    /// The banner above the call window once it is found, and the notification after three
    /// seconds without one.
    func offer(_ app: CallApp) {
        look(for: app, automatic: false, notifies: true)
    }

    /// Automatic recording: the same search for the same window, which goes to `onFound`
    /// the moment it can be captured instead of under a banner. Until then the notification
    /// offers it as usual after three seconds, when `notifies`, and is withdrawn once the
    /// window turns up.
    func watch(_ app: CallApp, notifies: Bool) {
        look(for: app, automatic: true, notifies: notifies)
    }

    /// Says an automatic recording started, with a Stop button.
    func announce(_ app: CallApp, video: Bool) {
        notifier.announce(app, video: video)
    }

    func withdrawAnnouncement() {
        notifier.withdrawAnnouncement()
    }

    private func look(for app: CallApp, automatic: Bool, notifies: Bool) {
        withdraw()
        guard app.muteButton != nil else {
            if notifies { notifier.offer(app) }
            return
        }
        let generation = generation
        let anchor = CallWindowAnchor(app: app)
        self.anchor = anchor
        task = Task { [weak self] in
            var fallbackShown = false
            let started = Date()
            while !Task.isCancelled {
                let window = await anchor.window()
                guard !Task.isCancelled else { return }
                if automatic, let window, let choice = await anchor.capture(window.identity) {
                    guard !Task.isCancelled else { return }
                    self?.found(choice, generation: generation)
                    return
                }
                let fallback = notifies && !fallbackShown && Date().timeIntervalSince(started) >= 3
                guard self?.update(app, window: automatic ? nil : window, generation: generation,
                                   fallback: fallback) == true
                else { return }
                if (window != nil && !automatic) || fallback { fallbackShown = true }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func found(_ choice: CaptureChoice, generation: UUID) {
        guard self.generation == generation else { return }
        withdraw()
        onFound(choice)
    }

    private func update(_ app: CallApp, window: MuteButton.Window?, generation: UUID, fallback: Bool) -> Bool {
        guard self.generation == generation else { return false }
        self.window = window
        if let window {
            notifier.withdraw()
            show(app, bounds: window.bounds)
        } else {
            panel?.orderOut(nil)
            if fallback { notifier.offer(app) }
        }
        return true
    }

    func withdraw() {
        generation = UUID()
        task?.cancel()
        task = nil
        anchor = nil
        window = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        notifier.withdraw()
    }

    private func show(_ app: CallApp, bounds: CGRect) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app.bundleID,
            let top = NSScreen.screens.first?.frame.maxY
        else { panel?.orderOut(nil); return }
        let window = CGRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height)
        guard let frame = CallReminderPlacement.frame(
            above: window, size: CallReminderView.size, screens: NSScreen.screens.map(\.visibleFrame))
        else { panel?.orderOut(nil); return }
        if panel == nil { panel = makePanel(app) }
        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
    }

    private func makePanel(_ app: CallApp) -> NSPanel {
        ReminderPanel(appName: app.name, record: { [weak self] in self?.record(video: $0) },
                      dismiss: { [weak self] in self?.withdraw() })
    }

    private func record(video: Bool) {
        guard let anchor, let window else { return }
        withdraw()
        let generation = generation
        Task { [weak self] in
            let choice = await anchor.capture(window.identity)
            guard let self, self.generation == generation else { return }
            onRecord(choice, video)
        }
    }

    private func chooseWindow(video: Bool) {
        withdraw()
        NSApplication.shared.activate(ignoringOtherApps: true)
        onChooseWindow(video)
    }
}

final class ReminderPanel: NSPanel {
    convenience init(appName: String, record: @escaping (Bool) -> Void, dismiss: @escaping () -> Void) {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "AnyRec recording reminder"
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        hasShadow = true
        contentView = NSHostingView(rootView: CallReminderView(appName: appName, record: record, dismiss: dismiss))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
