import AppKit
import ApplicationServices

typealias SlackElement = AXUIElement

enum SlackUI {
    static func attr<T>(_ el: SlackElement, _ key: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func string(_ el: SlackElement, _ key: String) -> String { attr(el, key) ?? "" }
    static func children(_ el: SlackElement) -> [SlackElement] { attr(el, "AXChildren") ?? [] }
    static func role(_ el: SlackElement) -> String { string(el, "AXRole") }
    static func id(_ el: SlackElement) -> String { string(el, "AXDOMIdentifier") }
    static func label(_ el: SlackElement) -> String {
        let title = string(el, "AXTitle")
        return title.isEmpty ? string(el, "AXDescription") : title
    }

    static func value(_ el: SlackElement) -> String {
        string(el, "AXValue").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func find(_ root: SlackElement, _ match: (SlackElement) -> Bool) -> SlackElement? {
        var todo = [root]
        let end = ProcessInfo.processInfo.systemUptime + 2
        while let el = todo.popLast(), ProcessInfo.processInfo.systemUptime < end {
            if match(el) { return el }
            if ["AXOutline", "AXList", "AXMenuBar"].contains(role(el)) { continue }
            todo.append(contentsOf: children(el).reversed())
        }
        return nil
    }

    static func wait<T>(seconds: TimeInterval = 2, _ read: () -> T?) -> T? {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if let value = read() { return value }
            Thread.sleep(forTimeInterval: 0.06)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return read()
    }
}
