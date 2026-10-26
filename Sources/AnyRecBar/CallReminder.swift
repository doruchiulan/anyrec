import AnyRecKit
import AppKit
import SwiftUI

@MainActor
final class CallReminder {
    private let onRecord: (CaptureChoice?) -> Void
    private let onChooseWindow: () -> Void
    private var task: Task<Void, Never>?
    private var panel: NSPanel?
    private var generation = UUID()
    private var anchor: CallWindowAnchor?
    private var window: MuteButton.Window?
    private lazy var notifier = CallNotifier { [weak self] in self?.chooseWindow() }

    init(onRecord: @escaping (CaptureChoice?) -> Void, onChooseWindow: @escaping () -> Void) {
        self.onRecord = onRecord
        self.onChooseWindow = onChooseWindow
    }

    func offer(_ app: CallApp) {
        withdraw()
        guard app.muteButton != nil else { notifier.offer(app); return }
        let generation = generation
        let anchor = CallWindowAnchor(app: app)
        self.anchor = anchor
        task = Task { [weak self] in
            var fallbackShown = false
            let started = Date()
            while !Task.isCancelled {
                let window = await anchor.window()
                guard !Task.isCancelled else { return }
                let fallback = !fallbackShown && Date().timeIntervalSince(started) >= 3
                guard self?.update(app, window: window, generation: generation, fallback: fallback) == true
                else { return }
                if window != nil || fallback { fallbackShown = true }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
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
            above: window, size: CGSize(width: 390, height: 54), screens: NSScreen.screens.map(\.visibleFrame))
        else { panel?.orderOut(nil); return }
        if panel == nil { panel = makePanel(app) }
        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
    }

    private func makePanel(_ app: CallApp) -> NSPanel {
        let panel = ReminderPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "AnyRec recording reminder"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: CallReminderView(
            appName: app.name, record: { [weak self] in self?.record() },
            dismiss: { [weak self] in self?.withdraw() }))
        return panel
    }

    private func record() {
        guard let anchor, let window else { return }
        withdraw()
        let generation = generation
        Task { [weak self] in
            let choice = await anchor.capture(window.identity)
            guard let self, self.generation == generation else { return }
            onRecord(choice)
        }
    }

    private func chooseWindow() {
        withdraw()
        NSApplication.shared.activate(ignoringOtherApps: true)
        onChooseWindow()
    }
}

private final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
