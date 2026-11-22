import SwiftUI

@MainActor
final class StatusPanelPresentation<Content: View>: NSObject, NSWindowDelegate {
    private let item: NSStatusItem
    private let content: () -> Content
    private var panel: StatusPanel?
    private var host: NSHostingController<Content>?
    private var sizeObservation: NSKeyValueObservation?
    private var monitors: [Any] = []
    private var spaceObserver: NSObjectProtocol?

    var isPanelOpen: Bool { panel?.isVisible == true }

    init(item: NSStatusItem, @ViewBuilder content: @escaping () -> Content) {
        self.item = item
        self.content = content
    }

    // MARK: The panel

    @objc func toggle() {
        if isPanelOpen { close() } else { open() }
    }

    /// Opens the panel under the icon, on the screen whose menu bar was clicked. Returns
    /// false when the icon is nowhere on screen — switched off, or hidden by the system
    /// in a full menu bar — so the caller can show something else.
    @discardableResult
    func open() -> Bool {
        guard item.isVisible, let icon = iconFrame() else { return false }
        let panel = panel ?? makePanel()
        self.panel = panel
        /// A fresh view each time, as the menu bar extra made one: the panel's `.task`
        /// refreshes the library, the microphones and the screen grant on every opening.
        let host = NSHostingController(rootView: content())
        host.sizingOptions = [.preferredContentSize]
        /// The panel follows its content, a turn of the run loop after SwiftUI says it
        /// changed: a window resized inside the layout pass that measured it is an AppKit
        /// exception.
        sizeObservation = host.observe(\.preferredContentSize) { [weak panel] host, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let panel, panel.isVisible, host.view.window === panel else { return }
                    let size = host.preferredContentSize
                    if size.height > 0, panel.frame.size != size { panel.setContentSize(size) }
                }
            }
        }
        self.host = host
        panel.contentView = PanelBackground(host.view)
        panel.anchor = Anchor(icon: icon, on: screen(containing: icon))
        panel.setContentSize(host.view.fittingSize)
        panel.orderFrontRegardless()
        panel.makeKey()
        item.button?.highlight(true)
        watchForDismissal()
        return true
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        stopWatching()
        panel.orderOut(nil)
        /// Torn down as the menu bar extra's content was, so a closed panel holds no views
        /// redrawing behind it ten times a second.
        panel.contentView = nil
        sizeObservation = nil
        host = nil
        item.button?.highlight(false)
    }

    func windowDidResignKey(_: Notification) { close() }

    private func makePanel() -> StatusPanel {
        let panel = StatusPanel()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }

    /// A menu goes away on a click anywhere else, on Escape, and when the Space changes.
    /// Clicks in this app's own windows take key status from the panel, which closes it;
    /// clicks in other apps only reach a global monitor.
    private func watchForDismissal() {
        stopWatching()
        if let outside = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in MainActor.assumeIsolated { self?.close() } })
        {
            monitors.append(outside)
        }
        if let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let number = event.windowNumber
            let closed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, number == panel.windowNumber else { return false }
                self.close()
                return true
            }
            return closed ? nil : event
        }) {
            monitors.append(escape)
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
    }

    private func stopWatching() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
    }

    // MARK: Where the icon is

    /// The icon's frame in screen coordinates, once it is in a menu bar. The status item's
    /// window starts at an arbitrary place and is moved into the menu bar after launch, so
    /// a frame that does not reach the top of its screen is not one to hang a panel from.
    ///
    /// With more than one display the system draws a copy of the item in every menu bar,
    /// while the button's own window is in one of them. A click on another display is
    /// answered under the pointer, in that display's menu bar.
    private func iconFrame() -> NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        /// The window, not the button, spans the menu bar's height: on a display with a
        /// notch the button is shorter than the bar and stops short of the top.
        guard frame.width > 0, let home = screen(containing: window.frame),
              window.frame.maxY >= home.frame.maxY - 1 else { return nil }
        let pointer = NSEvent.mouseLocation
        guard let clicked = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }),
              clicked != home, pointer.y >= clicked.frame.maxY - frame.height
        else { return frame }
        return NSRect(x: pointer.x - frame.width / 2, y: clicked.frame.maxY - frame.height,
                      width: frame.width, height: frame.height)
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        let middle = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { NSMouseInRect(middle, $0.frame, false) }
    }

    /// Calls back once the item has been placed in the menu bar and stayed put for a moment,
    /// or with false after a few seconds if it never is.
    func whenPlaced(_ then: @escaping (Bool) -> Void) {
        var last: NSRect?
        var attempts = 60
        func look() {
            let frame = iconFrame()
            if let frame, frame == last { return then(true) }
            last = frame
            attempts -= 1
            guard attempts > 0, item.isVisible else { return then(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { look() }
        }
        look()
    }
}
