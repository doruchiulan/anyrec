import AppKit

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
final class PanelBackground: NSVisualEffectView {
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
