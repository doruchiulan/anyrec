import AppKit

enum OneDriveLinkWindow {
    static func matches(_ title: String, fileName: String) -> Bool {
        ["Share \"\(fileName)\"", "Share “\(fileName)”"].contains(title)
    }

    static func copyButton(for fileName: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.OneDrive").first else {
            return nil
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.35)
        let windows: [AXUIElement] = SlackUI.attr(root, "AXWindows") ?? []
        let matching = windows.filter { matches(SlackUI.label($0), fileName: fileName) }
        guard matching.count == 1 else { return nil }
        return SlackUI.find(matching[0]) {
            SlackUI.role($0) == "AXButton" && SlackUI.label($0).lowercased() == "copy link"
                && SlackUI.attr($0, "AXEnabled") as Bool? == true
        }
    }
}
