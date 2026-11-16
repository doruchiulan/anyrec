import AnyRecKit
import Foundation
import ScreenCaptureKit

actor CallWindowAnchor {
    private let app: CallApp
    private var reader: MuteButton.Reader?

    init(app: CallApp) {
        self.app = app
    }

    /// The call window. `focused` is the banner's case, which sits above the call only
    /// while it is the app's focused window; the menu bar panel takes it either way.
    func window(focused: Bool = true) -> MuteButton.Window? {
        if reader == nil {
            reader = app.muteButton.flatMap { MuteButton.Reader(bundleID: app.bundleID, button: $0) }
        }
        return focused ? reader?.focusedWindow() : reader?.callWindow()
    }

    func capture(_ expected: UUID, focused: Bool = true) async -> CaptureChoice? {
        guard window(focused: focused)?.identity == expected,
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
            let current = window(focused: focused), current.identity == expected
        else { return nil }
        let candidates = content.windows.filter(\.isOnScreen).compactMap { window -> CallWindowMatch.Candidate? in
            guard let owner = window.owningApplication, owner.bundleIdentifier == app.bundleID else { return nil }
            return CallWindowMatch.Candidate(id: window.windowID, processID: owner.processID,
                                            bounds: window.frame, title: window.title, layer: window.windowLayer)
        }
        return CallWindowMatch.choice(for: current, in: candidates)
    }
}
