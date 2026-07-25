import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct WindowInfo: Sendable, Equatable {
    public let id: CGWindowID
    public let title: String
    public let application: String
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

    public static func windows(bundleID: String? = nil) async throws -> [WindowInfo] {
        let windows = try await content().windows.filter { window in
            guard let bundleID else { return true }
            return window.owningApplication?.bundleIdentifier == bundleID
        }
        return
            windows
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            .map {
                WindowInfo(
                    id: $0.windowID,
                    title: $0.title ?? "—",
                    application: $0.owningApplication?.applicationName ?? "—",
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

    public static func isRunning(bundleID: String) async throws -> Bool {
        try await content().applications.contains { $0.bundleIdentifier == bundleID }
    }
}
