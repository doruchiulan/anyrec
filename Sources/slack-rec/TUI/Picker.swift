import Foundation

struct PickerItem {
    let label: String
    let detail: String?
    let isHeader: Bool

    init(label: String, detail: String? = nil, isHeader: Bool = false) {
        self.label = label
        self.detail = detail
        self.isHeader = isHeader
    }

    static func header(_ text: String) -> PickerItem {
        PickerItem(label: text, isHeader: true)
    }
}

/// A single-choice list. Headers are drawn but skipped over when moving.
enum Picker {
    static func run(title: String, items: [PickerItem], selected: Int?) -> Int? {
        guard items.contains(where: { !$0.isHeader }) else { return nil }
        var cursor = selected.flatMap { items[$0].isHeader ? nil : $0 } ?? firstSelectable(items)

        while true {
            Terminal.write(render(title: title, items: items, cursor: cursor))
            switch Terminal.readKey() {
            case .up: cursor = step(items, from: cursor, by: -1)
            case .down: cursor = step(items, from: cursor, by: 1)
            case .enter, .right: return cursor
            case .escape, .interrupt: return nil
            case .character("q"): return nil
            case .character("k"): cursor = step(items, from: cursor, by: -1)
            case .character("j"): cursor = step(items, from: cursor, by: 1)
            default: break
            }
        }
    }

    private static func firstSelectable(_ items: [PickerItem]) -> Int {
        items.firstIndex { !$0.isHeader } ?? 0
    }

    private static func step(_ items: [PickerItem], from index: Int, by delta: Int) -> Int {
        var next = index
        for _ in 0..<items.count {
            next += delta
            guard items.indices.contains(next) else { return index }
            if !items[next].isHeader { return next }
        }
        return index
    }

    private static func render(title: String, items: [PickerItem], cursor: Int) -> String {
        let width = Terminal.size().columns
        var lines = ["", "  " + styled(title, .bold), ""]

        for (index, item) in visible(items, cursor: cursor) {
            if item.isHeader {
                lines.append("  " + styled(item.label, .dim))
                continue
            }
            let text = clip(item.detail.map { "\(item.label)  \($0)" } ?? item.label, to: width - 6)
            lines.append(
                index == cursor
                    ? "  " + styled("› " + text, .bold, .cyan)
                    : "    " + text
            )
        }

        lines += ["", "  " + styled("↑↓ move   ⏎ choose   esc cancel", .dim)]
        return Terminal.home + lines.map { $0 + Terminal.clearLine }.joined(separator: "\r\n")
            + "\r\n" + Terminal.clearToEnd
    }

    /// Keeps the cursor on screen for lists longer than the terminal.
    private static func visible(
        _ items: [PickerItem], cursor: Int
    ) -> [(offset: Int, element: PickerItem)] {
        let capacity = max(5, Terminal.size().rows - 8)
        guard items.count > capacity else { return Array(items.enumerated()) }
        let start = min(max(0, cursor - capacity / 2), items.count - capacity)
        return Array(items.enumerated())[start..<(start + capacity)].map { $0 }
    }
}

/// Clips unstyled text so styling can be applied afterwards without counting ANSI codes.
func clip(_ text: String, to width: Int) -> String {
    guard width > 1, text.count > width else { return text }
    return text.prefix(width - 1) + "…"
}
