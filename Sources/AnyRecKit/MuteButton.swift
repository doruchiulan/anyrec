import AppKit
import ApplicationServices
import Foundation

/// The call app's own mute control, read through accessibility.
///
/// Core Audio cannot see a mute the app keeps to itself — Teams holds the microphone
/// open and feeds it silence — but the app still has to show the user, and the button
/// it does that with is in the accessibility tree with its state in its name. Needs
/// the Accessibility grant, which is the terminal's for the CLI, as Screen Recording is.
public struct MuteButton: Sendable, Equatable {
    /// What the button is called when the microphone is off, and when it is on. A
    /// prefix, because some apps append the shortcut.
    public let muted: String
    public let live: String

    public init(muted: String, live: String) {
        self.muted = muted
        self.live = live
    }

    /// Nil for any other button.
    public func state(of title: String) -> Bool? {
        if title.hasPrefix(muted) { return true }
        if title.hasPrefix(live) { return false }
        return nil
    }
}

extension MuteButton {
    public struct Window: Sendable {
        public let identity: UUID
        public let processID: pid_t
        public let bounds: CGRect
        public let title: String?
    }

    /// Finds the button in one of the app's windows, then re-reads just that element:
    /// one round trip, as often as asked. The walk that finds it is the expensive part
    /// — thousands of elements in a calendar window — so it is repeated only every few
    /// seconds while there is no meeting window to find it in.
    public final class Reader {
        static let searchInterval: TimeInterval = 5
        static let timeout: Float = 0.5
        static let maximumDepth = 40

        private let button: MuteButton
        private let app: AXUIElement
        private var element: AXUIElement?
        private var window: AXUIElement?
        private var windowIdentity = UUID()
        private let processID: pid_t
        private var lastSearch = Date.distantPast

        /// Nil without the Accessibility grant, or when the app is not running.
        public init?(bundleID: String, button: MuteButton) {
            guard AXIsProcessTrusted(),
                let running = NSRunningApplication.runningApplications(
                    withBundleIdentifier: bundleID
                ).first
            else { return nil }
            self.button = button
            processID = running.processIdentifier
            app = AXUIElementCreateApplication(running.processIdentifier)
            AXUIElementSetMessagingTimeout(app, Self.timeout)
            /// Chromium exposes web content only to clients that ask for it; without
            /// this the tree stops at the window's close button. Electron has its own
            /// switch for the same thing, so both are thrown.
            for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
                AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue)
            }
        }

        /// Nil when no window holds the button: no meeting on screen, or none yet.
        public func muted() -> Bool? {
            if let element, let state = Self.title(of: element).flatMap(button.state) {
                return state
            }
            element = nil
            window = nil
            guard Date().timeIntervalSince(lastSearch) >= Self.searchInterval else { return nil }
            lastSearch = Date()
            element = find()
            return element.flatMap(Self.title).flatMap(button.state)
        }

        private func find() -> AXUIElement? {
            guard let windows: [AXUIElement] = Self.value(app, kAXWindowsAttribute) else {
                return nil
            }
            for window in windows {
                if let found = search(window, depth: 0) {
                    self.window = window
                    windowIdentity = UUID()
                    return found
                }
            }
            return nil
        }

        public func focusedWindow() -> Window? {
            guard muted() != nil, let window,
                let focused: AXUIElement = Self.value(app, kAXFocusedWindowAttribute),
                CFEqual(window, focused),
                let position: AXValue = Self.value(window, kAXPositionAttribute),
                let size: AXValue = Self.value(window, kAXSizeAttribute),
                Self.value(window, kAXMinimizedAttribute) as Bool? != true
            else { return nil }
            var origin = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position, .cgPoint, &origin),
                AXValueGetValue(size, .cgSize, &dimensions),
                dimensions.width > 0, dimensions.height > 0
            else { return nil }
            return Window(identity: windowIdentity, processID: processID,
                          bounds: CGRect(origin: origin, size: dimensions),
                          title: Self.value(window, kAXTitleAttribute))
        }

        private func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < Self.maximumDepth else { return nil }
            if let role: String = Self.value(element, kAXRoleAttribute), role == kAXButtonRole,
                Self.title(of: element).flatMap(button.state) != nil
            {
                return element
            }
            guard let children: [AXUIElement] = Self.value(element, kAXChildrenAttribute) else {
                return nil
            }
            for child in children {
                if let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }

        /// Slack's button has an empty title and the words in its description, so an
        /// empty title counts as none.
        private static func title(of element: AXUIElement) -> String? {
            if let title: String = value(element, kAXTitleAttribute), !title.isEmpty {
                return title
            }
            return value(element, kAXDescriptionAttribute)
        }

        private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
            var out: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success
            else { return nil }
            return out as? T
        }
    }
}
