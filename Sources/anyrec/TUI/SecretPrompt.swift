import Foundation

/// A single-line entry for something that must not be read over a shoulder. What was
/// typed is never drawn: this is a screen-recording tool, and the setup screen is one
/// keystroke from being shared. Only the last few characters show, which is enough to
/// tell a paste that landed from one that did not.
enum SecretPrompt {
    /// Nil when the user backed out. Escape is the only way out that is not the key
    /// itself — every printable character belongs to what is being typed.
    static func run(title: String, lines: [String]) -> String? {
        var entry = ""
        while true {
            Terminal.write(render(title: title, lines: lines, entry: entry))
            switch Terminal.readKey() {
            case .enter: if !entry.isEmpty { return entry }
            case .backspace: if !entry.isEmpty { entry.removeLast() }
            case .escape, .interrupt: return nil
            case .character(let character) where isPrintable(character): entry.append(character)
            default: break
            }
        }
    }

    static func mask(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let shown = text.count > 8 ? 4 : 0
        let hidden = min(text.count - shown, 32)
        return String(repeating: "•", count: hidden) + text.suffix(shown)
    }

    private static func isPrintable(_ character: Character) -> Bool {
        !character.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func render(title: String, lines: [String], entry: String) -> String {
        var screen = ["", "  " + styled(title, .bold), ""]
        screen += lines.map { "  " + styled($0, .dim) }
        screen += ["", "  " + field(entry), ""]
        screen += ["  " + styled("⏎ save   ⌫ delete   esc cancel", .dim)]

        return Terminal.home + screen.map { $0 + Terminal.clearLine }.joined(separator: "\r\n")
            + "\r\n" + Terminal.clearToEnd
    }

    private static func field(_ entry: String) -> String {
        guard !entry.isEmpty else { return styled("paste it here", .dim) }
        return styled(mask(entry), .cyan)
            + styled("  \(entry.count) characters", .dim)
    }
}
