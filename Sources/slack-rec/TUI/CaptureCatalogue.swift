import Foundation
import SlackRecKit

/// Everything ScreenCaptureKit will record, laid out as a pickable list.
struct CaptureCatalogue {
    let items: [PickerItem]
    let choices: [Int: CaptureChoice]

    static func load() async throws -> CaptureCatalogue {
        async let applications = ContentInventory.applications()
        async let displays = ContentInventory.displays()
        async let windows = ContentInventory.windows()

        var builder = Builder()
        builder.add(.auto, detail: "recommended")

        let apps = try await applications
        builder.section("Whole app", entries: apps.filter(\.isKnownCallApp).map(entry))
        builder.section("Displays", entries: try await displays.map(entry))
        builder.section("Other apps", entries: apps.filter { !$0.isKnownCallApp }.map(entry))
        builder.section("Single window", entries: try await sortedWindows(windows).map(entry))

        return CaptureCatalogue(items: builder.items, choices: builder.choices)
    }

    func index(of choice: CaptureChoice) -> Int? {
        choices.first { $0.value.target == choice.target }?.key
    }

    private static func sortedWindows(_ windows: [WindowInfo]) -> [WindowInfo] {
        windows.sorted {
            let (a, b) = (CallApps.isKnown($0.bundleID), CallApps.isKnown($1.bundleID))
            return a == b ? $0.application < $1.application : a && !b
        }
    }

    private static func entry(_ app: ApplicationInfo) -> Entry {
        Entry(
            choice: CaptureChoice(
                target: .application(bundleID: app.bundleID), label: app.name
            ),
            detail: "\(app.windowCount) window\(app.windowCount == 1 ? "" : "s")"
        )
    }

    private static func entry(_ display: DisplayInfo) -> Entry {
        Entry(
            choice: CaptureChoice(
                target: .display(index: display.index), label: "Display \(display.index)"
            ),
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

    struct Entry {
        let choice: CaptureChoice
        let detail: String?
    }

    private struct Builder {
        var items: [PickerItem] = []
        var choices: [Int: CaptureChoice] = [:]

        mutating func add(_ choice: CaptureChoice, detail: String?) {
            choices[items.count] = choice
            items.append(PickerItem(label: choice.label, detail: detail))
        }

        mutating func section(_ title: String, entries: [Entry]) {
            guard !entries.isEmpty else { return }
            items.append(.header(title))
            for entry in entries { add(entry.choice, detail: entry.detail) }
        }
    }
}
