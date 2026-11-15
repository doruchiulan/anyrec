import AppKit
import Observation
import SwiftUI

/// The menu bar helper: an AppKit status item whose button shows what the controller is
/// doing, and a panel under it with `MenuPanel`. It replaced SwiftUI's `MenuBarExtra`,
/// which cannot be opened from code, so a launch by hand could not show anything.
///
/// The button is drawn by AppKit from an image and a title, re-read through Observation
/// whenever what they show changes. An `NSHostingView` in a status button sizes and
/// highlights unreliably, and a symbol and a few digits need nothing SwiftUI does.
@MainActor
final class StatusItem: NSObject, NSWindowDelegate {
    private let controller: RecordingController
    private let item: NSStatusItem
    private var panel: StatusPanel?
    private var host: NSHostingController<MenuPanel>?
    private var sizeObservation: NSKeyValueObservation?
    private var monitors: [Any] = []
    private var spaceObserver: NSObjectProtocol?
    private var visibility: NSKeyValueObservation?
    /// What the button shows now, so it is only touched when that changes and the menu
    /// bar redraws once a second while recording, not on every change the controller sees.
    private var shown: (symbol: String, title: String)?

    var isPanelOpen: Bool { panel?.isVisible == true }

    init(controller: RecordingController) {
        self.controller = controller
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            /// Like a menu: it opens on the press, not the release.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            button.setAccessibilityTitle("AnyRec")
        }
        /// ⌘-dragging the item out of the menu bar is the same choice as the switch in
        /// Settings › General, and the switch says so afterwards, as `MenuBarExtra`'s
        /// `isInserted` binding did.
        item.behavior = .removalAllowed
        visibility = item.observe(\.isVisible) { [weak self] item, _ in
            let visible = item.isVisible
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.controller.showsMenuBarExtra != visible else { return }
                    self.controller.showsMenuBarExtra = visible
                }
            }
        }
        render()
    }

    // MARK: The button

    /// Re-armed after every change: `withObservationTracking` reports one change and stops.
    private func render() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
    }

    private func apply() {
        let visible = controller.showsMenuBarExtra
        if item.isVisible != visible { item.isVisible = visible }
        if !visible { close() }

        /// A symbol when idle, a phone while a call app holds the microphone and nothing is
        /// recorded, a clock while background work runs, and the running time beside the
        /// filled symbol once there is one, because the panel is usually shut. The state is
        /// carried by the symbol and the clock rather than by colour: a status item is drawn
        /// as a template, so a tint would be stripped. The clock is the controller's held
        /// text, which changes once a second.
        let next: (symbol: String, title: String)
        if controller.isRecording {
            next = ("record.circle.fill", controller.clock)
        } else if !controller.working.isEmpty {
            next = ("clock", "")
        } else if controller.callApp != nil {
            next = ("phone.circle.fill", "")
        } else {
            next = ("record.circle", "")
        }
        guard let button = item.button, shown?.symbol != next.symbol || shown?.title != next.title else { return }
        if shown?.symbol != next.symbol {
            let image = NSImage(systemSymbolName: next.symbol, accessibilityDescription: "AnyRec")
            image?.isTemplate = true
            button.image = image
        }
        if shown?.title != next.title { button.title = next.title }
        shown = next
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
        let host = NSHostingController(rootView: MenuPanel(controller: controller))
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

/// Where the panel hangs from: the icon it opened under, the frame of the screen it is on,
/// and the bottom of that screen's menu bar when one is showing.
struct Anchor: Equatable {
    let icon: NSRect
    var screen: NSRect?
    var menuBarBottom: CGFloat?

    init(icon: NSRect, screen: NSRect? = nil, menuBarBottom: CGFloat? = nil) {
        self.icon = icon
        self.screen = screen
        self.menuBarBottom = menuBarBottom
    }

    @MainActor
    init(icon: NSRect, on screen: NSScreen?) {
        let bar = screen.flatMap { $0.visibleFrame.maxY < $0.frame.maxY ? $0.visibleFrame.maxY : nil }
        self.init(icon: icon, screen: screen?.frame, menuBarBottom: bar)
    }

    /// Just under the menu bar, its leading edge at the icon's like a menu's, moved left as
    /// far as it takes to stay on the screen near its right edge. The icon's window is taller
    /// than some menu bars, so the bar's own bottom is used where the screen has one showing.
    func frame(for size: NSSize) -> NSRect {
        let gap: CGFloat = 4, margin: CGFloat = 8
        let top = menuBarBottom ?? icon.minY
        var origin = NSPoint(x: icon.minX, y: top - gap - size.height)
        if let screen {
            origin.x = min(origin.x, screen.maxX - margin - size.width)
            origin.x = max(origin.x, screen.minX + margin)
        }
        return NSRect(origin: origin, size: size)
    }
}

/// A borderless panel that can be key without activating the app, so the app in front
/// keeps its menu bar and its focus, as it does under a menu. Every frame it is given is
/// re-hung from the anchor, so the panel grows downwards when its content does.
final class StatusPanel: NSPanel {
    var anchor: Anchor?
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        title = "AnyRec"
        level = .popUpMenu
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(anchor?.frame(for: frameRect.size) ?? frameRect, display: flag)
    }

    override func cancelOperation(_: Any?) { onCancel?() }
}

/// The menu material under the SwiftUI content, with rounded corners.
private final class PanelBackground: NSVisualEffectView {
    init(_ content: NSView) {
        super.init(frame: NSRect(origin: .zero, size: content.fittingSize))
        material = .menu
        blendingMode = .behindWindow
        state = .active
        maskImage = Self.mask(radius: 12)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
