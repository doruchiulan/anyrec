import AppKit

struct SlackSendUnconfirmed: LocalizedError {
    var errorDescription: String? { "Check the conversation in Slack before sending again." }
}

enum SlackComposer {
    private typealias UI = SlackUI

    static func send(_ text: String, editor: SlackElement, stillSelected: () -> Bool) throws {
        guard !text.isEmpty, let body = composer(of: editor), let button = sendButton(in: body),
              stillSelected(), let initial: String = UI.attr(editor, "AXValue") else {
            throw DraftError("Couldn’t verify Slack’s message box.")
        }
        let occupied = DraftError("This conversation has a different draft. Clear or send it in Slack first.")
        guard !hasAttachment(in: body) else { throw occupied }
        if empty(initial) {
            guard !enabled(button) else { throw occupied }
            try paste(text, editor: editor, stillSelected: stillSelected)
        } else if !matches(initial, text) {
            throw occupied
        }
        guard UI.wait({ enabled(button) && matches(UI.string(editor, "AXValue"), text) ? true : nil }) == true,
              stillSelected(), !hasAttachment(in: body), let current = sendButton(in: body),
              CFEqual(button, current), enabled(current), matches(UI.string(editor, "AXValue"), text) else {
            throw DraftError("Slack didn’t prepare the full summary for this conversation.")
        }
        let result = AXUIElementPerformAction(current, kAXPressAction as CFString)
        guard [.success, .cannotComplete].contains(result),
              UI.wait(seconds: 5, { (UI.attr(editor, "AXValue") as String?).map(empty) == true ? true : nil }) == true else {
            throw SlackSendUnconfirmed()
        }
    }

    private static func composer(of editor: SlackElement) -> SlackElement? {
        var element: SlackElement? = editor
        while let node = element {
            let classes: [String] = UI.attr(node, "AXDOMClassList") ?? []
            if classes.contains("p-workspace__input") { return node }
            element = UI.attr(node, "AXParent")
        }
        return nil
    }

    private static func sendButton(in body: SlackElement) -> SlackElement? {
        UI.find(body) { UI.role($0) == "AXButton" && UI.label($0) == "Send now" }
    }

    private static func hasAttachment(in body: SlackElement) -> Bool {
        var nodes = [body]
        while let node = nodes.popLast() {
            let classes: [String] = UI.attr(node, "AXDOMClassList") ?? []
            if classes.contains(where: { $0.hasPrefix("c-file_upload") || $0.hasPrefix("p-file_upload") ||
                $0.hasPrefix("c-file_gallery__item") }) { return true }
            if UI.role(node) == "AXButton" {
                let label = UI.label(node).lowercased()
                if label.hasPrefix("remove file") || label.hasPrefix("remove attachment") { return true }
            }
            if UI.role(node) != "AXTextArea" { nodes += UI.children(node) }
        }
        return false
    }

    private static func enabled(_ element: SlackElement) -> Bool { UI.attr(element, "AXEnabled") as Bool? == true }
    private static func empty(_ text: String) -> Bool { text == "" || text == "\n" }

    static func matches(_ actual: String, _ expected: String) -> Bool {
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .newlines)
        }
        return normalized(actual) == normalized(expected)
    }

    private static func paste(_ text: String, editor: SlackElement, stillSelected: () -> Bool) throws {
        var pid: pid_t = 0
        guard AXUIElementGetPid(editor, &pid) == .success else { throw DraftError("Slack’s editor closed.") }
        let root = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(editor, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        func focused() -> Bool {
            guard let focus: SlackElement = UI.attr(root, "AXFocusedUIElement") else { return false }
            return CFEqual(focus, editor)
        }
        guard UI.wait({ focused() ? true : nil }) == true,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            throw DraftError("Couldn’t focus the selected conversation in Slack.")
        }
        try withPasteboard(text) {
            guard stillSelected(), focused(), let value: String = UI.attr(editor, "AXValue"), empty(value) else {
                throw DraftError("The Slack draft changed. Check the selected conversation.")
            }
            for event in [down, up] { event.flags = .maskCommand; event.postToPid(pid) }
            guard UI.wait(seconds: 4, { matches(UI.string(editor, "AXValue"), text) ? true : nil }) == true else {
                throw DraftError("Slack didn’t insert the full summary. Check the draft in Slack.")
            }
        }
    }

    private static func withPasteboard(_ text: String, perform: () throws -> Void) throws {
        let board = NSPasteboard.general
        let original = board.changeCount
        let previous = try (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), copy.setData(data, forType: type) else {
                    throw DraftError("Couldn’t preserve the clipboard for pasting into Slack.")
                }
            }
            return copy
        }
        guard board.changeCount == original else { throw DraftError("The clipboard changed. Try Send again.") }
        board.clearContents()
        var owned = board.changeCount
        defer {
            if board.changeCount == owned {
                board.clearContents()
                if !previous.isEmpty { board.writeObjects(previous) }
            }
        }
        guard board.setString(text, forType: .string) else { throw DraftError("Couldn’t prepare the summary for Slack.") }
        owned = board.changeCount
        try perform()
    }
}
