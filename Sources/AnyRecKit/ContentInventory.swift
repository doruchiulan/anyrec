import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct WindowInfo: Sendable, Equatable {
    public let id: CGWindowID
    public let title: String
    public let application: String
    public let bundleID: String
    public let width: Int
    public let height: Int
}

public struct DisplayInfo: Sendable, Equatable {
    public let index: Int
    public let id: CGDirectDisplayID
    public let width: Int
    public let height: Int
}

/// Read-only view of what ScreenCaptureKit is willing to capture.
public enum ContentInventory {
    private static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Apps draw into layer 0 — wallpaper, menu bar, Dock and status items do not —
    /// and what survives that but stays thumbnail-sized is a popup, not a target.
    static func isUserFacing(layer: Int, width: CGFloat, height: CGFloat) -> Bool {
        layer == 0 && min(width, height) >= 120
    }

    private static func isUserFacing(_ window: SCWindow) -> Bool {
        isUserFacing(
            layer: window.windowLayer, width: window.frame.width, height: window.frame.height
        )
    }

    public static func windows(bundleIDs: Set<String>? = nil) async throws -> [WindowInfo] {
        let windows = try await content().windows.filter { window in
            guard isUserFacing(window) else { return false }
            guard let bundleIDs else { return true }
            guard let id = window.owningApplication?.bundleIdentifier else { return false }
            return bundleIDs.contains(id)
        }
        return
            windows
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            .map {
                WindowInfo(
                    id: $0.windowID,
                    title: $0.title ?? "—",
                    application: $0.owningApplication?.applicationName ?? "—",
                    bundleID: $0.owningApplication?.bundleIdentifier ?? "",
                    width: Int($0.frame.width),
                    height: Int($0.frame.height)
                )
            }
    }

    public static func displays() async throws -> [DisplayInfo] {
        try await content().displays.enumerated().map { index, display in
            DisplayInfo(
                index: index,
                id: display.displayID,
                width: display.width,
                height: display.height
            )
        }
    }

}
