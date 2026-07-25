import Foundation

public struct CallApp: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    /// Browsers host Meet, Whereby and the rest, but they also host everything else,
    /// so they are offered after the dedicated clients rather than auto-selected.
    public let isBrowser: Bool

    public init(bundleID: String, name: String, isBrowser: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.isBrowser = isBrowser
    }
}

/// The apps worth looking for when nobody said what to capture.
public enum CallApps {
    public static let known: [CallApp] = [
        CallApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        CallApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
        CallApp(bundleID: "com.microsoft.teams", name: "Microsoft Teams (classic)"),
        CallApp(bundleID: "us.zoom.xos", name: "Zoom"),
        CallApp(bundleID: "com.google.meetbar", name: "Google Meet"),
        CallApp(bundleID: "Cisco-Systems.Spark", name: "Webex"),
        CallApp(bundleID: "com.cisco.webexmeetingsapp", name: "Webex Meetings"),
        CallApp(bundleID: "com.hnc.Discord", name: "Discord"),
        CallApp(bundleID: "com.skype.skype", name: "Skype"),
        CallApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
        CallApp(bundleID: "desktop.WhatsApp", name: "WhatsApp"),
        CallApp(bundleID: "ru.keepcoder.Telegram", name: "Telegram"),
        CallApp(bundleID: "com.tdesktop.Telegram", name: "Telegram Desktop"),
        CallApp(bundleID: "com.apple.FaceTime", name: "FaceTime"),
        CallApp(bundleID: "com.google.Chrome", name: "Chrome", isBrowser: true),
        CallApp(bundleID: "com.microsoft.edgemac", name: "Edge", isBrowser: true),
        CallApp(bundleID: "com.apple.Safari", name: "Safari", isBrowser: true),
        CallApp(bundleID: "company.thebrowser.Browser", name: "Arc", isBrowser: true),
        CallApp(bundleID: "org.mozilla.firefox", name: "Firefox", isBrowser: true),
    ]

    public static let bundleIDs = Set(known.map(\.bundleID))

    public static func app(for bundleID: String) -> CallApp? {
        known.first { $0.bundleID == bundleID }
    }

    public static func isKnown(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }
}
