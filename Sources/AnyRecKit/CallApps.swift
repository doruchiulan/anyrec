import Foundation

public struct CallApp: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    /// How the app's own mute control is labelled, when anyrec knows how to read it.
    public let muteButton: MuteButton?

    public init(bundleID: String, name: String, muteButton: MuteButton? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.muteButton = muteButton
    }
}

/// The apps whose windows are worth offering first.
public enum CallApps {
    public static let known: [CallApp] = [
        CallApp(
            bundleID: "com.tinyspeck.slackmacgap", name: "Slack",
            muteButton: MuteButton(muted: "Unmute microphone", live: "Mute microphone")),
        CallApp(
            bundleID: "com.microsoft.teams2", name: "Microsoft Teams",
            muteButton: MuteButton(muted: "Unmute mic", live: "Mute mic")),
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
        CallApp(bundleID: "com.google.Chrome", name: "Chrome"),
        CallApp(bundleID: "com.microsoft.edgemac", name: "Edge"),
        CallApp(bundleID: "com.apple.Safari", name: "Safari"),
        CallApp(bundleID: "company.thebrowser.Browser", name: "Arc"),
        CallApp(bundleID: "org.mozilla.firefox", name: "Firefox"),
    ]

    public static let bundleIDs = Set(known.map(\.bundleID))

    public static func isKnown(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    /// Every known app and the one recording, each with its mute button if it has one
    /// — what a recording watches the microphone through.
    public static func watchList(including bundleID: String?) -> [String: MuteButton?] {
        var apps = Dictionary(uniqueKeysWithValues: known.map { ($0.bundleID, $0.muteButton) })
        if let bundleID, apps.index(forKey: bundleID) == nil { apps[bundleID] = .some(nil) }
        return apps
    }
}
