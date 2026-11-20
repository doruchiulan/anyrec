import AppKit

struct DraftError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

actor SlackRecipients {
    private typealias UI = SlackUI
    private var team: String?
    static let bundle = "com.tinyspeck.slackmacgap"
    private let changed = DraftError("The Slack workspace changed. Reopen the picker and choose again.")

    private func window() throws -> SlackElement {
        guard AXIsProcessTrusted() else { throw DraftError("Allow Accessibility access to read the Slack sidebar.") }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundle).first else {
            throw DraftError("Open Slack and sign in first.")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.4)
        guard let window: SlackElement = UI.attr(root, "AXFocusedWindow") else {
            throw DraftError("Open a Slack workspace window first.")
        }
        return window
    }

    func read() throws -> [SlackRecipient] {
        team = nil
        let window = try window()
        guard let location = SlackLocation(window: window) else { throw DraftError("Open a workspace in Slack, then reopen the picker.") }
        let rows = try SlackSidebar.read(window)
        guard let current = try? self.window(), CFEqual(window, current),
              SlackLocation(window: current)?.team == location.team else { throw changed }
        team = location.team
        return rows
    }

    func send(_ recipient: SlackRecipient, text: String) async throws {
        let window = try window()
        guard let team, let current = SlackLocation(window: window), current.team == team else { throw changed }
        if current.conversation != recipient.id {
            guard let url = URL(string: "slack://channel?team=\(team)&id=\(recipient.id)"),
                  let slack = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundle) else {
                throw DraftError("Couldn’t open the conversation in Slack.")
            }
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: slack, configuration: .init())
        }
        _ = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundle).first?.activate()
        func currentWindow() -> SlackElement? {
            guard let active = try? self.window(), let location = SlackLocation(window: active),
                  location.team == team, location.conversation == recipient.id else { return nil }
            return active
        }
        guard let editor = UI.wait(seconds: 5, {
            currentWindow().flatMap { Self.editor(in: $0, recipient: recipient) }
        }) else { throw DraftError("Slack didn’t open the selected conversation.") }
        try SlackComposer.send(text, editor: editor) {
            guard let window = currentWindow(), let current = Self.editor(in: window, recipient: recipient) else { return false }
            return CFEqual(current, editor)
        }
    }

    private static func editor(in window: SlackElement, recipient: SlackRecipient) -> SlackElement? {
        UI.find(window) {
            guard UI.role($0) == "AXTextArea" else { return false }
            let label = UI.label($0)
            guard label.hasPrefix("Message to ") else { return false }
            let actual = label.dropFirst("Message to ".count).replacingOccurrences(of: "&amp;", with: "&")
            return name(actual) == name(recipient.name)
        }
    }

    private static func name(_ text: String) -> String {
        let name = text.hasSuffix(" (you)") ? String(text.dropLast(6)) : text
        return name.hasPrefix("#") ? String(name.dropFirst()) : name
    }
}
