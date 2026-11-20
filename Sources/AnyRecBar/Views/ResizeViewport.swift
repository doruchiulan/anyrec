import AppKit
import SwiftUI

struct ResizeViewport<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> ResizePane<Content> {
        ResizePane(content: content, scenePhase: context.environment.scenePhase)
    }

    func updateNSView(_ pane: ResizePane<Content>, context: Context) {
        pane.host.rootView = PaneContent(content: content, scenePhase: context.environment.scenePhase)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ResizePane<Content>, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

struct PaneContent<Content: View>: View {
    let content: Content
    let scenePhase: ScenePhase

    var body: some View { content.environment(\.scenePhase, scenePhase) }
}

final class ResizePane<Content: View>: NSView {
    let host: NSHostingView<PaneContent<Content>>
    private var preview: ResizePreview?

    init(content: Content, scenePhase: ScenePhase) {
        host = NSHostingView(rootView: PaneContent(content: content, scenePhase: scenePhase))
        super.init(frame: .zero)
        host.sizingOptions = []
        clipsToBounds = true
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        fitContent(duringDrag: inLiveResize)
    }

    override func layout() {
        super.layout()
        fitContent(duringDrag: inLiveResize)
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        guard preview == nil, !NSWorkspace.shared.isVoiceOverEnabled,
              !NSWorkspace.shared.isSwitchControlEnabled, !(window?.firstResponder is NSTextView),
              window?.attachedSheet == nil, let page = ResizePreview(content: host) else { return }
        addSubview(page)
        page.showVideo(from: host)
        preview = page
        host.removeFromSuperview()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endPreview() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func endPreview() {
        guard let preview else { return }
        addSubview(host, positioned: .below, relativeTo: preview)
        preview.restoreVideo()
        preview.removeFromSuperview()
        self.preview = nil
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        endPreview()
        fitContent(duringDrag: false)
    }

    func fitContent(duringDrag: Bool) {
        guard preview == nil, host.frame != bounds else { return }
        // Reflowing the transcript at every pointer event stalls native window tracking.
        if duringDrag, !host.frame.isEmpty, abs(bounds.width - host.frame.width) < 64,
           abs(bounds.height - host.frame.height) < 64 { return }
        host.frame = bounds
    }
}
