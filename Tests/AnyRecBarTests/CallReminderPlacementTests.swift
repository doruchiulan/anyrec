import CoreGraphics
import Testing

@testable import AnyRecBar

@Suite("Call reminder placement")
struct CallReminderPlacementTests {
    private let size = CGSize(width: 390, height: 54)

    @Test("centers above a call window with a small gap")
    func aboveWindow() throws {
        let window = CGRect(x: 100, y: 100, width: 800, height: 500)
        let frame = try #require(CallReminderPlacement.frame(
            above: window, size: size, screens: [CGRect(x: 0, y: 0, width: 1440, height: 900)]))
        #expect(frame.midX == window.midX)
        #expect(frame.minY == window.maxY + 8)
    }

    @Test("stays visible when the call fills the display")
    func fullScreen() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 876)
        let frame = try #require(CallReminderPlacement.frame(
            above: CGRect(x: 0, y: 0, width: 1440, height: 900), size: size, screens: [screen]))
        #expect(screen.contains(frame))
        #expect(frame.maxY == screen.maxY)
    }

    @Test("follows a call onto a display left of the main one")
    func secondaryDisplay() throws {
        let secondary = CGRect(x: -1280, y: 0, width: 1280, height: 800)
        let frame = try #require(CallReminderPlacement.frame(
            above: CGRect(x: -1200, y: 100, width: 800, height: 500), size: size,
            screens: [CGRect(x: 0, y: 0, width: 1440, height: 900), secondary]))
        #expect(secondary.contains(frame))
        #expect(frame.midX == -800)
    }

    @Test("clamps the banner when the call extends beyond a display edge")
    func partiallyOffscreen() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = try #require(CallReminderPlacement.frame(
            above: CGRect(x: -450, y: 100, width: 800, height: 500), size: size, screens: [screen]))
        #expect(screen.contains(frame))
        #expect(frame.minX == screen.minX)
    }

    @Test("does not display a banner for an offscreen or invalid window")
    func unavailableWindow() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        #expect(CallReminderPlacement.frame(
            above: CGRect(x: 2000, y: 100, width: 800, height: 500), size: size, screens: screens) == nil)
        #expect(CallReminderPlacement.frame(above: .zero, size: size, screens: screens) == nil)
    }
}
