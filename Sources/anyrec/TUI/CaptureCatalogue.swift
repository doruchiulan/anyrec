import Foundation
import AnyRecKit

/// Everything ScreenCaptureKit will record, laid out as a pickable list.
struct CaptureCatalogue {
    let items: [PickerItem]
    let choices: [Int: CaptureChoice]

    static func load() async throws -> CaptureCatalogue {
        async let displays = ContentInventory.displays()
        async let windows = ContentInventory.windows()

        var builder = Builder()
        builder.section("Windows", entries: try await sortedWindows(windows).map(entry))
        builder.section("Displays", entries: try await displays.map(entry))

        return CaptureCatalogue(items: builder.items, choices: builder.choices)
    }

    func index(of choice: CaptureChoice?) -> Int? {
        guard let choice else { return nil }
        return choices.first { $0.value.target == choice.target }?.key
    }

    private static func sortedWindows(_ windows: [WindowInfo]) -> [WindowInfo] {
        windows.sorted {
            let (a, b) = (CallApps.isKnown($0.bundleID), CallApps.isKnown($1.bundleID))
            return a == b ? $0.application < $1.application : a && !b
        }
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
