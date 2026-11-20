import AppKit
import SwiftUI

struct LiveResizeVideo<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> VideoSlot<Content> { VideoSlot(content: content) }

    func updateNSView(_ slot: VideoSlot<Content>, context: Context) { slot.host.rootView = content }
}

class VideoSlotView: NSView {
    let picture: NSView

    init(picture: NSView) {
        self.picture = picture
        super.init(frame: .zero)
        addSubview(picture)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        if picture.superview === self { picture.frame = bounds }
    }

    func restorePicture() {
        addSubview(picture)
        picture.frame = bounds
    }
}

final class VideoSlot<Content: View>: VideoSlotView {
    let host: NSHostingView<Content>

    init(content: Content) {
        host = NSHostingView(rootView: content)
        host.sizingOptions = []
        super.init(picture: host)
    }
}

final class ResizePreview: NSView {
    private weak var video: VideoSlotView?
    override var isFlipped: Bool { true }

    init?(content: NSView) {
        let area = content.bounds
        guard !area.isEmpty, let bitmap = content.bitmapImageRepForCachingDisplay(in: area) else { return nil }
        content.cacheDisplay(in: area, to: bitmap)
        let image = NSImage(size: area.size)
        image.addRepresentation(bitmap)
        super.init(frame: content.frame)
        let page = NSImageView(frame: bounds)
        page.image = image
        page.imageScaling = .scaleNone
        addSubview(page)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showVideo(from content: NSView) {
        guard let slot = Self.videoSlot(in: content), !slot.visibleRect.isEmpty else { return }
        // AppKit's bitmap omits the hardware video surface, so keep the actual player and its overlays live.
        let frame = slot.convert(slot.bounds, to: self)
        video = slot
        addSubview(slot.picture)
        slot.picture.frame = frame
    }

    func restoreVideo() {
        video?.restorePicture()
        video = nil
    }

    private static func videoSlot(in view: NSView) -> VideoSlotView? {
        if let slot = view as? VideoSlotView { return slot }
        for child in view.subviews {
            if let slot = videoSlot(in: child) { return slot }
        }
        return nil
    }
}
