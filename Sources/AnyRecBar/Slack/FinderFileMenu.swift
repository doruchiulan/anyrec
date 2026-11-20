import AppKit

enum FinderFileMenu {
    private typealias AX = SlackUI

    static func selectedFile(_ file: URL, in finder: AXUIElement) -> AXUIElement? {
        guard let window: AXUIElement = AX.attr(finder, "AXFocusedWindow") else { return nil }
        var pending = [window]
        while let element = pending.popLast() {
            if let url: URL = AX.attr(element, "AXURL"), url.isFileURL,
               url.standardizedFileURL == file.standardizedFileURL,
               isOnlySelection(element) { return element }
            switch AX.role(element) {
            case "AXToolbar", "AXMenuBar": continue
            case "AXOutline", "AXTable":
                pending.append(contentsOf: AX.attr(element, "AXSelectedRows") as [AXUIElement]? ?? [])
            default:
                let selected: [AXUIElement] = AX.attr(element, "AXSelectedChildren") ?? []
                pending.append(contentsOf: selected.isEmpty ? AX.children(element) : selected)
            }
        }
        return nil
    }

    private static func isOnlySelection(_ element: AXUIElement) -> Bool {
        var ancestor: AXUIElement? = element
        var selected = false
        while let node = ancestor {
            if AX.attr(node, "AXSelected") as Bool? == true { selected = true }
            for key in ["AXSelectedRows", "AXSelectedChildren"] {
                if let items: [AXUIElement] = AX.attr(node, key), !items.isEmpty {
                    return selected && items.count == 1
                }
            }
            ancestor = AX.attr(node, "AXParent")
        }
        return false
    }

    static func menuWindows(pid: pid_t) -> [CGWindowID: CGRect] {
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        var result: [CGWindowID: CGRect] = [:]
        for window in list where window[kCGWindowOwnerPID as String] as? pid_t == pid {
            guard window[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.popUpMenuWindow)),
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            result[id] = rect
        }
        return result
    }

    static func openedMenu(pid: pid_t, excluding before: Set<CGWindowID>) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        for (id, rect) in menuWindows(pid: pid) where !before.contains(id) {
            var item: AXUIElement?
            // Finder publishes its context menu in a separate popup window outside its AX window tree.
            guard AXUIElementCopyElementAtPosition(system, Float(rect.midX), Float(rect.minY + 15), &item) == .success,
                  let item else { continue }
            var owner: pid_t = 0
            guard AXUIElementGetPid(item, &owner) == .success, owner == pid else { continue }
            let menu: AXUIElement? = AX.role(item) == "AXMenu" ? item : AX.attr(item, "AXParent")
            if let menu, AX.role(menu) == "AXMenu" { return menu }
        }
        return nil
    }

    static func copyCommand(in menu: AXUIElement) -> AXUIElement? {
        let items = AX.children(menu)
        guard items.contains(where: { AX.label($0) == "View Online" || AX.label($0) == "Manage Access" }) else { return nil }
        let copy = items.filter { AX.role($0) == "AXMenuItem" && AX.label($0) == "Copy Link" }
        guard copy.count == 1, AX.attr(copy[0], "AXEnabled") as Bool? == true else { return nil }
        return copy[0]
    }
}
