import Foundation

/// Everything ScreenCaptureKit will record, in the order worth offering it: call apps'
/// windows first, then every other window, then displays.
public struct CaptureCatalogue: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let choice: CaptureChoice
        public let detail: String
    }

    public struct Section: Sendable, Equatable {
        public let title: String
        public let entries: [Entry]
    }

    public let sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    public static func load() async throws -> CaptureCatalogue {
        async let displays = ContentInventory.displays()
        async let windows = ContentInventory.windows()

        let sections = [
            Section(title: "Windows", entries: try await callAppsFirst(windows).map(entry)),
            Section(title: "Displays", entries: try await displays.map(entry)),
        ]
        return CaptureCatalogue(sections: sections.filter { !$0.entries.isEmpty })
    }

    /// Flattened in display order, which is what an index into a list of these means.
    public var entries: [Entry] { sections.flatMap(\.entries) }

    static func callAppsFirst(_ windows: [WindowInfo]) -> [WindowInfo] {
        windows.sorted {
            let (a, b) = (CallApps.isKnown($0.bundleID), CallApps.isKnown($1.bundleID))
            return a == b ? $0.application < $1.application : a && !b
        }
    }

    private static func entry(_ display: DisplayInfo) -> Entry {
        Entry(
            choice: CaptureChoice(target: .display(index: display.index)),
            detail: "\(display.width)×\(display.height)"
        )
    }

    private static func entry(_ window: WindowInfo) -> Entry {
        Entry(
            choice: CaptureChoice(
                target: .window(id: window.id),
                label: "\(window.application) — \(window.title)"
            ),
            detail: "\(window.width)×\(window.height)"
        )
    }
}
