import AnyRecKit
import Foundation

/// A call window ready to record, listed at the top of the menu bar panel so pressing
/// Record skips macOS's picker.
struct OngoingCall: Identifiable, Equatable {
    let app: CallApp
    let choice: CaptureChoice
    /// The window's title, when it has one worth showing.
    let title: String?

    var id: CaptureChoice { choice }
}

/// The windows of the call `CallWatch` saw. For Slack and Teams this is the window holding
/// the mute control, found through accessibility and matched to ScreenCaptureKit's window
/// the way the banner matches it, focused or not. Other call apps have no control anyrec
/// can read, so their windows are listed only when there are few enough to tell apart.
/// Anything else is left to Other Window….
actor OngoingCallFinder {
    static let limit = 3

    private var anchor: (app: CallApp, anchor: CallWindowAnchor)?
    private var last: (identity: UUID, call: OngoingCall)?

    func calls(for app: CallApp) async -> [OngoingCall] {
        guard app.muteButton != nil else { return await windows(of: app) }
        if anchor?.app != app {
            anchor = (app, CallWindowAnchor(app: app))
            last = nil
        }
        guard let anchor = anchor?.anchor, let window = await anchor.window(focused: false) else {
            last = nil
            return []
        }
        /// Re-reading the window is one accessibility round trip; resolving it against
        /// ScreenCaptureKit is not, so that happens only when the window changes.
        if let last, last.identity == window.identity, last.call.title == window.title { return [last.call] }
        guard let choice = await anchor.capture(window.identity, focused: false) else {
            last = nil
            return []
        }
        let call = OngoingCall(app: app, choice: choice, title: window.title.flatMap { $0.isEmpty ? nil : $0 })
        last = (window.identity, call)
        return [call]
    }

    private func windows(of app: CallApp) async -> [OngoingCall] {
        let windows = ((try? await ContentInventory.windows()) ?? []).filter {
            $0.bundleID == app.bundleID || $0.bundleID.hasPrefix(app.bundleID + ".")
        }
        guard (1...Self.limit).contains(windows.count) else { return [] }
        return windows.map { window in
            let title = window.title == "—" || window.title.isEmpty ? nil : window.title
            return OngoingCall(
                app: app,
                choice: CaptureChoice(target: .window(id: window.id),
                                      label: title.map { "\(window.application) — \($0)" } ?? window.application),
                title: title)
        }
    }
}
