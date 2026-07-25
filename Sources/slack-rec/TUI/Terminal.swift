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

    /// `pollTenths` is VTIME: reads give up after that many tenths of a second and
    /// return nothing, which is what paces the redraw loop.
    static func enterRawMode(pollTenths: UInt8 = 1) {
        var term = termios()
        guard tcgetattr(STDIN_FILENO, &term) == 0 else { return }
        saved = term

        term.c_lflag &= ~(UInt(ECHO) | UInt(ICANON))
        withUnsafeMutablePointer(to: &term.c_cc) { tuple in
            tuple.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { slots in
                slots[Int(VMIN)] = 0
                slots[Int(VTIME)] = pollTenths
            }
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &term)
        write(alternateScreenOn + hideCursor + clearScreen)
    }

    static func restore() {
        write(showCursor + alternateScreenOff)
        guard var term = saved else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &term)
        saved = nil
    }

    /// Nil means the poll interval elapsed with no key pressed.
    static func readKey() -> Key? {
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
        switch byte {
        case 0x03: return .interrupt
        case 0x0A, 0x0D: return .enter
        case 0x1B: return readEscapeSequence()
        case 0x7F, 0x08: return .backspace
        default: return .character(Character(UnicodeScalar(byte)))
        }
    }

    private static func readEscapeSequence() -> Key {
        var bracket: UInt8 = 0
        var code: UInt8 = 0
        guard read(STDIN_FILENO, &bracket, 1) == 1, bracket == 0x5B,
            read(STDIN_FILENO, &code, 1) == 1
        else { return .escape }

        switch code {
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        default: return .escape
        }
    }
}
