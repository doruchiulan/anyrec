import AnyRecKit
import Foundation
import ScreenCaptureKit

actor CallWindowAnchor {
    private let app: CallApp
    private var reader: MuteButton.Reader?

    init(app: CallApp) {
        self.app = app
    }

    func window() -> MuteButton.Window? {
        if reader == nil {
            reader = app.muteButton.flatMap { MuteButton.Reader(bundleID: app.bundleID, button: $0) }
        }
        return reader?.focusedWindow()
    }

    func capture(_ expected: UUID) async -> CaptureChoice? {
        guard window()?.identity == expected,
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
            let current = window(), current.identity == expected
        else { return nil }
        let candidates = content.windows.filter(\.isOnScreen).compactMap { window -> CallWindowMatch.Candidate? in
            guard let owner = window.owningApplication, owner.bundleIdentifier == app.bundleID else { return nil }
            return CallWindowMatch.Candidate(id: window.windowID, processID: owner.processID,
                                            bounds: window.frame, title: window.title, layer: window.windowLayer)
        }
        return CallWindowMatch.choice(for: current, in: candidates)
    }
}
