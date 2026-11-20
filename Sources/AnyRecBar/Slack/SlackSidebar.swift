import AppKit

struct SlackRecipient: Identifiable {
    let id: String
    let name: String
    let symbol: String
    var isChannel: Bool { symbol == "number" }
}

struct SlackLocation: Equatable {
    let team: String
    let conversation: String?

    init?(window: SlackElement) {
        guard let web = SlackUI.find(window, { SlackUI.role($0) == "AXWebArea" }),
              let url: URL = SlackUI.attr(web, "AXURL"), url.host == "app.slack.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "client", parts[1].hasPrefix("T") else { return nil }
        team = parts[1]
        conversation = parts.dropFirst(2).first
    }
}

enum SlackSidebar {
    private typealias UI = SlackUI

    static func read(_ window: SlackElement) throws -> [SlackRecipient] {
        guard let sidebar = UI.find(window, {
            UI.role($0) == "AXOutline" && UI.label($0) == "Channels and direct messages"
        }) else { throw DraftError("Open the channel sidebar in Slack, then reopen the picker.") }
        var pending = [sidebar]
        var seen = Set<String>()
        var recipients = [SlackRecipient]()
        while let item = pending.popLast() {
            if UI.role(item) == "AXRow", let recipient = recipient(item) {
                if seen.insert(recipient.id).inserted { recipients.append(recipient) }
            } else {
                pending.append(contentsOf: UI.children(item).reversed())
            }
        }
        return recipients
    }

    private static func recipient(_ row: SlackElement) -> SlackRecipient? {
        let id = UI.id(row)
        guard let first = id.first, "CDG".contains(first), id.count >= 8,
              id.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
              let group = UI.children(row).first(where: { classes($0).contains("p-channel_sidebar__channel") }),
              let title = UI.children(group).first(where: { UI.role($0) == "AXStaticText" }) else { return nil }
        let name = UI.value(title)
        guard !name.isEmpty else { return nil }
        let symbol: String
        if classes(group).contains("p-channel_sidebar__channel--mpim") { symbol = "person.2" }
        else if first == "D" { symbol = "person" }
        else { symbol = "number" }
        return SlackRecipient(id: id, name: name, symbol: symbol)
    }

    private static func classes(_ el: SlackElement) -> [String] { UI.attr(el, "AXDOMClassList") ?? [] }
}
