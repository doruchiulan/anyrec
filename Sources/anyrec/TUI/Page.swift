import Foundation

/// Full-screen pages that say one thing: ask, report, or wait. The lists and meters
/// have their own screens; this is for everything in between.
enum Page {
    static func confirm(title: String, lines: [String], action: String) -> Bool {
        while true {
            Terminal.write(
                render(title: title, lines: lines, footer: "⏎ \(action)   esc cancel"))
            switch Terminal.readKey() {
            case .enter, .character("y"): return true
            case .escape, .interrupt, .character("q"), .character("n"): return false
            default: break
            }
        }
    }

    static func notice(title: String, lines: [String]) {
        Terminal.write(render(title: title, lines: lines, footer: "any key to go back"))
        while Terminal.readKey() == nil {}
    }

    static func working(title: String, lines: [String] = []) {
        Terminal.write(render(title: title, lines: lines, footer: nil))
    }

    /// Embedded newlines are laid out as their own lines: errors arrive wrapped, and a
    /// raw `\n` in a raw-mode terminal steps down a row without returning to column one.
    private static func render(title: String, lines: [String], footer: String?) -> String {
        let width = max(20, Terminal.size().columns - 6)
        var screen = ["", "  " + styled(title, .bold), ""]
        screen += lines.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false) }
            .map { "  " + fit(String($0), to: width) }
        if let footer { screen += ["", "  " + styled(footer, .dim)] }

        return Terminal.home + screen.map { $0 + Terminal.clearLine }.joined(separator: "\r\n")
            + "\r\n" + Terminal.clearToEnd
    }

    /// `clip` counts characters, so a line that is already styled would be cut by its
    /// own escape codes. Those come pre-sized from whoever built them.
    private static func fit(_ text: String, to width: Int) -> String {
        text.contains("\u{1B}") ? text : clip(text, to: width)
    }
}
