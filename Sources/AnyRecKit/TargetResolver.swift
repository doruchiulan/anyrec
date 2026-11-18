import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum TargetResolver {
    /// Every window is recorded into this frame, its picture fitted inside with its
    /// proportions kept and black around it. The frame used to be the window's size when
    /// the recording started, and a file cannot change size part-way: a Slack huddle begun
    /// as a 1920×332 strip kept that frame when the window grew to show a shared screen,
    /// so the share was recorded 332 pixels high. 16:9 at 1080p because a shared screen
    /// arrives as a call's video stream, rarely sharper than that, and it is what every
    /// player takes; 2560×1440 kept small Retina text a little sharper at twice the pixels
    /// and compression time. Displays keep their own size: they cannot change shape.
    public static let windowFrame = (width: 1920, height: 1080)

    /// Windows off the current Space are included here and nowhere else. What is worth
    /// *offering* is what is on screen, but by the time an id has been picked the window
    /// may have been dragged to another desktop — and `desktopIndependentWindow` follows
    /// it there, so refusing to resolve it would be the one place that did not.
    public static func resolve(_ target: CaptureTarget, ownerPID: pid_t? = nil) async throws -> ResolvedTarget {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        return try resolve(target, in: content, ownerPID: ownerPID)
    }

    public static func resolve(
        _ target: CaptureTarget, in content: SCShareableContent, ownerPID: pid_t? = nil
    ) throws -> ResolvedTarget {
        switch target {
        case .display(let index): try resolveDisplay(index, in: content)
        case .window(let id): try resolveWindow(id, in: content, ownerPID: ownerPID)
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
        _ id: CGWindowID, in content: SCShareableContent, ownerPID: pid_t?
    ) throws -> ResolvedTarget {
        guard let window = content.windows.first(where: { $0.windowID == id }),
            ownerPID == nil || window.owningApplication?.processID == ownerPID else {
            throw TargetError.windowNotFound(id)
        }
        /// `desktopIndependentWindow:` asks SkyLight which displays the window's rect
        /// touches, and SkyLight aborts the process (CGS_REQUIRE_INIT) if nothing has
        /// opened a window-server connection yet. A CLI never does; this opens one.
        _ = CGMainDisplayID()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return ResolvedTarget(
            filter: filter, width: windowFrame.width, height: windowFrame.height,
            describing: window.title ?? "window \(id)",
            bundleID: window.owningApplication?.bundleIdentifier)
    }

    private static func describe(_ filter: SCContentFilter, as label: String) -> ResolvedTarget {
        let scale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        return ResolvedTarget(
            filter: filter,
            width: evenPixels(rect.width * scale),
            height: evenPixels(rect.height * scale),
            describing: label
        )
    }

    /// H.264 and HEVC both require even dimensions.
    private static func evenPixels(_ value: CGFloat) -> Int {
        let pixels = max(2, Int(value.rounded()))
        return pixels - (pixels % 2)
    }
}
