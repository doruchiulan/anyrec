import Darwin
import Foundation

enum Key: Equatable {
    case up, down, left, right
    case enter, escape, backspace, interrupt
    case character(Character)
}

enum Style: String {
    case reset = "\u{1B}[0m"
    case bold = "\u{1B}[1m"
    case dim = "\u{1B}[2m"
    case inverse = "\u{1B}[7m"
    case red = "\u{1B}[31m"
    case green = "\u{1B}[32m"
    case yellow = "\u{1B}[33m"
    case blue = "\u{1B}[34m"
    case cyan = "\u{1B}[36m"
}

func styled(_ text: String, _ styles: Style...) -> String {
    styles.map(\.rawValue).joined() + text + Style.reset.rawValue
}

/// Raw-mode terminal handling: just enough ANSI to draw a screen and read keys.
enum Terminal {
    static let alternateScreenOn = "\u{1B}[?1049h"
    static let alternateScreenOff = "\u{1B}[?1049l"
    /// Terminals translate the wheel into arrow keys on the alternate screen, which
    /// arrive as the same bytes a real arrow key does. Turning that off is the only
    /// place the two can still be told apart.
    static let alternateScrollOff = "\u{1B}[?1007l"
    static let alternateScrollOn = "\u{1B}[?1007h"
    /// Whatever the shell left behind: in application cursor mode arrows arrive as
    /// SS3, which this reads as nothing at all.
    static let normalCursorKeys = "\u{1B}[?1l"
    static let hideCursor = "\u{1B}[?25l"
    static let showCursor = "\u{1B}[?25h"
    static let home = "\u{1B}[H"
    static let clearScreen = "\u{1B}[2J\u{1B}[H"
    static let clearToEnd = "\u{1B}[J"
    static let clearLine = "\u{1B}[K"

    static var isInteractive: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    static func size() -> (rows: Int, columns: Int) {
        var window = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &window) == 0, window.ws_col > 0 else {
            return (24, 80)
        }
        return (Int(window.ws_row), Int(window.ws_col))
    }

    static func write(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
    }

    private static var saved: termios?
    private static var signals: Interrupt?

    /// Takes over the terminal, and with it Ctrl-C: a full-screen app has files to
    /// finalise, so signals are turned into an `.interrupt` key rather than being
    /// left to kill the process where it stands.
    ///
    /// `pollTenths` is VTIME: reads give up after that many tenths of a second and
    /// return nothing, which is what paces the redraw loop.
    static func enterRawMode(pollTenths: UInt8 = 1) {
        var term = termios()
        guard tcgetattr(STDIN_FILENO, &term) == 0 else { return }
        saved = term
        signals = Interrupt.watching()

        term.c_lflag &= ~(UInt(ECHO) | UInt(ICANON))
        withUnsafeMutablePointer(to: &term.c_cc) { tuple in
            tuple.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { slots in
                slots[Int(VMIN)] = 0
                slots[Int(VTIME)] = pollTenths
            }
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &term)
        write(
            alternateScreenOn + alternateScrollOff + normalCursorKeys + hideCursor + clearScreen
        )
    }

    static func restore() {
        write(alternateScrollOn + showCursor + alternateScreenOff)
        signals = nil
        guard var term = saved else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &term)
        saved = nil
    }

    /// Nil means the poll interval elapsed with nothing to report.
    static func readKey() -> Key? {
        if signals?.isTriggered == true { return .interrupt }
        guard let byte = readByte() else { return nil }
        return KeyDecoder.decode(first: byte, next: readByte)
    }

    private static func readByte() -> UInt8? {
        var byte: UInt8 = 0
        return read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
    }
}
