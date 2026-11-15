import AppKit
import Testing

@testable import AnyRecBar

@Suite("Menu bar panel placement")
struct StatusPanelAnchorTests {
    /// The arrangement measured on a two-display Mac: the icon's window is 39 points tall,
    /// taller than the external display's 30-point menu bar, and pokes above its top.
    private let screen = NSRect(x: -5120, y: 532, width: 5120, height: 2160)
    private let icon = NSRect(x: -619, y: 2658, width: 32, height: 39)
    private let size = NSSize(width: 300, height: 283)

    @Test("hangs from the menu bar's bottom with its leading edge at the icon's")
    func underTheIcon() {
        let frame = Anchor(icon: icon, screen: screen, menuBarBottom: 2662).frame(for: size)
        #expect(frame.minX == icon.minX)
        #expect(frame.maxY == 2658)
        #expect(frame.size == size)
    }

    @Test("falls back to the icon's bottom when the menu bar is hidden")
    func autoHiddenMenuBar() {
        let frame = Anchor(icon: icon, screen: screen).frame(for: size)
        #expect(frame.maxY == icon.minY - 4)
    }

    @Test("moves left to stay on a screen whose edge the icon is near")
    func nearTheRightEdge() {
        let edge = NSRect(x: screen.maxX - 40, y: icon.minY, width: 32, height: 39)
        let frame = Anchor(icon: edge, screen: screen, menuBarBottom: 2662).frame(for: size)
        #expect(frame.maxX == screen.maxX - 8)
    }

    @Test("stays on a screen whose left edge the icon is near")
    func nearTheLeftEdge() {
        let edge = NSRect(x: screen.minX, y: icon.minY, width: 32, height: 39)
        let frame = Anchor(icon: edge, screen: screen, menuBarBottom: 2662).frame(for: size)
        #expect(frame.minX == screen.minX + 8)
    }

    @Test("keeps its top where it was when the content grows")
    @MainActor
    func growsDownwards() {
        let panel = StatusPanel()
        panel.anchor = Anchor(icon: icon, screen: screen, menuBarBottom: 2662)
        panel.setContentSize(NSSize(width: 300, height: 180))
        #expect(panel.frame.maxY == 2658)
        panel.setContentSize(size)
        #expect(panel.frame.maxY == 2658)
        #expect(panel.frame.height == size.height)
    }
}
