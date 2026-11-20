import AppKit
import SwiftUI
import Testing
@testable import AnyRecBar

@MainActor
struct ResizeViewportTests {
    @Test func fitsExactlyAtRestAndReflowsInStepsDuringDrag() {
        let pane = ResizePane(content: EmptyView(), scenePhase: .active)
        pane.setFrameSize(NSSize(width: 500, height: 400))
        pane.fitContent(duringDrag: false)
        let original = pane.bounds

        pane.host.frame = original.insetBy(dx: 20, dy: 0)
        let held = pane.host.frame
        pane.fitContent(duringDrag: true)
        #expect(pane.host.frame == held)
        pane.viewDidEndLiveResize()
        #expect(pane.host.frame == original)

        for size in [NSSize(width: 420, height: 400), NSSize(width: 500, height: 480), .zero] {
            pane.host.setFrameSize(size)
            pane.fitContent(duringDrag: true)
            #expect(pane.host.frame == original)
        }
    }

    @Test func previewReturnsTheSameVideoViewAfterAResize() throws {
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let window = NSWindow(contentRect: page.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        defer { window.contentView = nil }
        window.contentView = page
        let slot = VideoSlot(content: Color.blue)
        slot.frame = NSRect(x: 12, y: 20, width: 300, height: 170)
        page.addSubview(slot)
        let preview = try #require(ResizePreview(content: page))
        page.addSubview(preview)
        let expected = slot.convert(slot.bounds, to: preview)

        preview.showVideo(from: slot)
        #expect(slot.picture.superview === preview)
        #expect(slot.picture.frame == expected)
        preview.restoreVideo()
        #expect(slot.picture.superview === slot)
        #expect(slot.picture.frame == slot.bounds)
    }
}
