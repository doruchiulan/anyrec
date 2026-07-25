import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum TargetResolver {
    public static func resolve(_ target: CaptureTarget) async throws -> ResolvedTarget {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        return try resolve(target, in: content)
    }

    public static func resolve(
        _ target: CaptureTarget, in content: SCShareableContent
    ) throws -> ResolvedTarget {
        switch target {
        case .application(let bundleID): try resolveApplication(bundleID, in: content)
        case .display(let index): try resolveDisplay(index, in: content)
        case .window(let id): try resolveWindow(id, in: content)
        case .autoDetect: try resolveApplication(try detect(in: content), in: content)
        }
    }

    /// Dedicated clients win over browsers, and among equals the one with most windows.
    private static func detect(in content: SCShareableContent) throws -> String {
        let running = CallApps.known.filter { app in
            content.applications.contains { $0.bundleIdentifier == app.bundleID }
                && content.windows.contains { $0.owningApplication?.bundleIdentifier == app.bundleID }
        }
        guard let pick = running.first(where: { !$0.isBrowser }) ?? running.first else {
            throw TargetError.noCallAppRunning
        }
        return pick.bundleID
    }

    private static func resolveApplication(
        _ bundleID: String, in content: SCShareableContent
    ) throws -> ResolvedTarget {
        guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID })
        else { throw TargetError.applicationNotRunning(bundleID) }

        let windows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == bundleID
        }
        let display = try hostDisplay(for: windows, in: content)
        let filter = SCContentFilter(
            display: display, including: [app], exceptingWindows: []
        )
        let count = "\(windows.count) window\(windows.count == 1 ? "" : "s")"
        return describe(filter, as: "\(app.applicationName) (\(count))")
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
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return describe(filter, as: window.title ?? "window \(id)")
    }

    /// The display showing most of the app's largest window, falling back to the first display.
    private static func hostDisplay(
        for windows: [SCWindow], in content: SCShareableContent
    ) throws -> SCDisplay {
        guard let fallback = content.displays.first else { throw TargetError.noDisplays }
        guard let biggest = windows.max(by: { area($0.frame) < area($1.frame) }) else {
            return fallback
        }
        let best = content.displays.max { overlap($0.frame, biggest.frame) < overlap($1.frame, biggest.frame) }
        guard let best, overlap(best.frame, biggest.frame) > 0 else { return fallback }
        return best
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

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let hit = a.intersection(b)
        return hit.isNull ? 0 : area(hit)
    }
}
