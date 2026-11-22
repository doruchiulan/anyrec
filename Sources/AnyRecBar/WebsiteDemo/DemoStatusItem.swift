#if ANYREC_WEBSITE_DEMO
import SwiftUI

@MainActor
final class DemoStatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var started: Date?
    private var video = true
    private let stop: () -> Void
    private let open: () -> Void
    private let idle: () -> Void
    private lazy var presentation = StatusPanelPresentation(item: item) { [unowned self] in
        if let started {
            DemoRecording(started: started, video: video, stop: stop, open: showReview)
        }
    }

    init(stop: @escaping () -> Void, open: @escaping () -> Void, idle: @escaping () -> Void) {
        self.stop = stop
        self.open = open
        self.idle = idle
        super.init()
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(toggle)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    private func showReview() {
        presentation.close()
        open()
    }

    func record(_ video: Bool) {
        reset()
        self.video = video
        let start = Date()
        started = start
        updateButton(symbol: "waveform.badge.microphone", title: Wording.clock(0))
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.item.button?.title = Wording.clock(Date().timeIntervalSince(start)) }
        }
        presentation.whenPlaced { [weak self] placed in
            guard placed, let self, started == start else { return }
            presentation.open()
        }
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        started = nil
        presentation.close()
        updateButton(symbol: "waveform", title: "")
    }

    private func updateButton(symbol: String, title: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AnyRec Website Demo")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.title = title
    }

    @objc private func toggle() {
        if started == nil { idle() } else { presentation.toggle() }
    }
}
#endif
