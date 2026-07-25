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

public struct ApplicationInfo: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    public let windowCount: Int
    public let isKnownCallApp: Bool
}

/// Read-only view of what ScreenCaptureKit is willing to capture.
public enum ContentInventory {
    private static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    public static func windows(bundleIDs: Set<String>? = nil) async throws -> [WindowInfo] {
        let windows = try await content().windows.filter { window in
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

    public static func isRunning(bundleID: String) async throws -> Bool {
        try await content().applications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Every app with at least one capturable window, known call apps first.
    public static func applications() async throws -> [ApplicationInfo] {
        let shareable = try await content()
        let counts = shareable.windows.reduce(into: [String: Int]()) { tally, window in
            guard let id = window.owningApplication?.bundleIdentifier else { return }
            tally[id, default: 0] += 1
        }
        return
            shareable.applications
            .compactMap { app -> ApplicationInfo? in
                guard let count = counts[app.bundleIdentifier], count > 0,
                    !app.applicationName.isEmpty, !app.bundleIdentifier.isEmpty
                else { return nil }
                return ApplicationInfo(
                    bundleID: app.bundleIdentifier,
                    name: app.applicationName,
                    windowCount: count,
                    isKnownCallApp: CallApps.isKnown(app.bundleIdentifier)
                )
            }
            .sorted {
                ($0.isKnownCallApp ? 0 : 1, $0.name.lowercased())
                    < ($1.isKnownCallApp ? 0 : 1, $1.name.lowercased())
            }
    }

    public static func runningCallApps() async throws -> [ApplicationInfo] {
        try await applications().filter(\.isKnownCallApp)
    }
}
