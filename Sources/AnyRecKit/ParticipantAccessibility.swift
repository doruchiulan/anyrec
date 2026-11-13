import AppKit
import ApplicationServices

final class ParticipantAccessibility {
    struct Selection {
        let processID: pid_t
        let windowID: CGWindowID
        let bundleID: String
    }

    private let application: AXUIElement
    private let selection: Selection
    private let platform: ParticipantLabels.Platform

    init?(selection: Selection) {
        guard AXIsProcessTrusted(), let platform = ParticipantLabels.Platform(bundleID: selection.bundleID) else { return nil }
        self.selection = selection
        self.platform = platform
        application = AXUIElementCreateApplication(selection.processID)
        AXUIElementSetMessagingTimeout(application, 0.05)
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            AXUIElementSetAttributeValue(application, attribute as CFString, kCFBooleanTrue)
        }
    }

    func snapshot(deadline: TimeInterval) -> ParticipantLabels.Snapshot? {
        guard AXIsProcessTrusted(), let window = selectedWindow(deadline: deadline),
              value(window, kAXMinimizedAttribute) as Bool? != true else { return nil }
        var remaining = 1_500
        guard let root = read(window, depth: 0, remaining: &remaining, deadline: deadline) else { return nil }
        return ParticipantLabels.parse(root, platform: platform)
    }

    private func selectedWindow(deadline: TimeInterval) -> AXUIElement? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, selection.windowID) as? [[String: Any]],
              let entry = info.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == selection.windowID }),
              entry[kCGWindowOwnerPID as String] as? pid_t == selection.processID,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              let windows: [AXUIElement] = value(application, kAXWindowsAttribute) else { return nil }
        var matches: [AXUIElement] = []
        for window in windows {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            guard let position: AXValue = value(window, kAXPositionAttribute),
                  let size: AXValue = value(window, kAXSizeAttribute) else { continue }
            var origin = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions) else { continue }
            if abs(origin.x - rect.minX) < 2 && abs(origin.y - rect.minY) < 2
                && abs(dimensions.width - rect.width) < 2 && abs(dimensions.height - rect.height) < 2 {
                matches.append(window)
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func read(
        _ element: AXUIElement, depth: Int, remaining: inout Int, deadline: TimeInterval
    ) -> ParticipantLabels.Node? {
        guard depth < 40, remaining > 0, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        remaining -= 1
        let role: String = value(element, kAXRoleAttribute) ?? ""
        let identifier: String = value(element, kAXIdentifierAttribute) ?? ""
        // Chat, captions and text-entry content cannot identify the person speaking.
        if ["AXTextArea", "AXTextField"].contains(role)
            || ["chat", "message", "caption", "transcript"].contains(where: { identifier.lowercased().contains($0) }) {
            return ParticipantLabels.Node(role: role)
        }
        let labels = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute -> String? in
            guard let text: String = value(element, attribute), text.count <= 200 else { return nil }
            return text
        }
        var node = ParticipantLabels.Node(role: role, labels: labels,
            identifier: identifier,
            classes: value(element, "AXDOMClassList") ?? [])
        guard let children = children(of: element) else { return nil }
        for child in children {
            guard let read = read(child, depth: depth + 1, remaining: &remaining, deadline: deadline) else { return nil }
            node.children.append(read)
        }
        return node
    }

    private func children(of element: AXUIElement) -> [AXUIElement]? {
        var result: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &result)
        if status == .attributeUnsupported || status == .noValue { return [] }
        guard status == .success else { return nil }
        return result as? [AXUIElement]
    }

    private func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? T
    }
}
