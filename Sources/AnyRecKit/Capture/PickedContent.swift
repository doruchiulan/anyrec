import Foundation
import ScreenCaptureKit

/// The inverse of `TargetResolver`: what macOS's content picker handed back, read as the
/// target every interface already speaks in. Only the id is kept — the filter is built
/// again at record time, so one code path still resolves every recording.
public enum PickedContent {
    public static func choice(from filter: SCContentFilter) async -> CaptureChoice? {
        switch filter.style {
        case .window:
            guard let window = filter.includedWindows.first else { return nil }
            return CaptureChoice(
                target: .window(id: window.windowID),
                label: label(for: window)
            )
        case .display:
            guard let display = filter.includedDisplays.first,
                let known = try? await ContentInventory.displays()
                    .first(where: { $0.id == display.displayID })
            else { return nil }
            return CaptureChoice(target: .display(index: known.index))
        default:
            /// An application filter records the whole display with everything else
            /// masked out, which is not a target this records.
            return nil
        }
    }

    private static func label(for window: SCWindow) -> String {
        let application = window.owningApplication?.applicationName ?? "—"
        let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        return "\(application) — \(title)"
    }
}
