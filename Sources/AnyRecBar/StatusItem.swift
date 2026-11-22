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
final class StatusItem: NSObject {
    private let controller: RecordingController
    private let item: NSStatusItem
    private lazy var presentation = StatusPanelPresentation(item: item) { [controller] in
        MenuPanel(controller: controller)
    }
    private var visibility: NSKeyValueObservation?
    /// What the button shows now, so it is only touched when that changes and the menu
    /// bar redraws once a second while recording, not on every change the controller sees.
    private var shown: (symbol: String, title: String, animated: Bool)?
    /// The animated waveform shown while background work runs. A status button cannot run a
    /// symbol effect itself; an image view can, so one sits over the button's image for as
    /// long as the work does.
    private var animation: NSImageView?

    var isPanelOpen: Bool { presentation.isPanelOpen }

    init(controller: RecordingController) {
        self.controller = controller
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = item.button {
            button.target = presentation
            button.action = #selector(presentation.toggle)
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

        /// A waveform, badged by state: a microphone and the running time while recording (the
        /// panel is usually shut), its bars lighting up in turn while background work runs (the
        /// only state that moves, so it is noticed), a magnifying glass while a call app holds
        /// the microphone and nothing is recorded. The state is carried by the symbol, its
        /// motion and the clock rather than by colour: a status item is drawn as a template,
        /// so a tint would be stripped. The clock is the controller's held text, which changes
        /// once a second. Every symbol exists from macOS 15, below the 15.2 floor.
        let next: (symbol: String, title: String, animated: Bool)
        if controller.isRecording {
            next = ("waveform.badge.microphone", controller.clock, false)
        } else if !controller.working.isEmpty {
            next = ("waveform", "", true)
        } else if controller.callApp != nil {
            next = ("waveform.badge.magnifyingglass", "", false)
        } else {
            next = ("waveform", "", false)
        }
        guard let button = item.button,
              shown?.symbol != next.symbol || shown?.title != next.title || shown?.animated != next.animated
        else { return }
        if shown?.symbol != next.symbol || shown?.animated != next.animated {
            let image = NSImage(systemSymbolName: next.symbol, accessibilityDescription: "AnyRec")
            image?.isTemplate = true
            button.image = image
            animate(next.animated ? image : nil, in: button)
        }
        if shown?.title != next.title { button.title = next.title }
        shown = next
    }

    /// Runs the waveform's bars in turn over the button's own image, which stays underneath,
    /// invisible, to keep the item's width. Nil stops it and shows the button's image again.
    private func animate(_ image: NSImage?, in button: NSStatusBarButton) {
        animation?.removeFromSuperview()
        animation = nil
        guard let image else { return }
        let view = NSImageView(image: image)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.imageScaling = .scaleNone
        view.setAccessibilityElement(false)
        button.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        button.image = Self.blank(size: image.size)
        view.addSymbolEffect(.variableColor.iterative.reversing, options: .repeating)
        animation = view
    }

    /// An empty image the size of the symbol, so the item keeps its width under the animation.
    private static func blank(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.isTemplate = true
        return image
    }

    func close() { presentation.close() }
    func open() -> Bool { presentation.open() }
    func whenPlaced(_ then: @escaping (Bool) -> Void) { presentation.whenPlaced(then) }
}
