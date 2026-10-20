import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum TargetResolver {
    /// Windows off the current Space are included here and nowhere else. What is worth
    /// *offering* is what is on screen, but by the time an id has been picked the window
    /// may have been dragged to another desktop — and `desktopIndependentWindow` follows
    /// it there, so refusing to resolve it would be the one place that did not.
    public static func resolve(_ target: CaptureTarget) async throws -> ResolvedTarget {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        return try resolve(target, in: content)
    }

    public static func resolve(
        _ target: CaptureTarget, in content: SCShareableContent
    ) throws -> ResolvedTarget {
        switch target {
        case .display(let index): try resolveDisplay(index, in: content)
        case .window(let id): try resolveWindow(id, in: content)
        }
    }

    private static func resolveDisplay(
        _ index: Int, in content: SCShareableContent
    ) throws -> ResolvedTarget {
        guard content.displays.indices.contains(index) else {
            throw TargetError.displayOutOfRange(index: index, count: content.displays.count)
        }
        let display = content.displays[index]
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return describe(filter, as: "display \(index)")
    }

    private static func resolveWindow(
        _ id: CGWindowID, in content: SCShareableContent
    ) throws -> ResolvedTarget {
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw TargetError.windowNotFound(id)
        }
        /// `desktopIndependentWindow:` asks SkyLight which displays the window's rect
        /// touches, and SkyLight aborts the process (CGS_REQUIRE_INIT) if nothing has
        /// opened a window-server connection yet. A CLI never does; this opens one.
        _ = CGMainDisplayID()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return describe(
            filter, as: window.title ?? "window \(id)",
            ownedBy: window.owningApplication?.bundleIdentifier)
    }

    private static func describe(
        _ filter: SCContentFilter, as label: String, ownedBy bundleID: String? = nil
    ) -> ResolvedTarget {
        let scale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        return ResolvedTarget(
            filter: filter,
            width: evenPixels(rect.width * scale),
            height: evenPixels(rect.height * scale),
            describing: label,
            bundleID: bundleID
        )
    }

    /// H.264 and HEVC both require even dimensions.
    private static func evenPixels(_ value: CGFloat) -> Int {
        let pixels = max(2, Int(value.rounded()))
        return pixels - (pixels % 2)
    }
}
