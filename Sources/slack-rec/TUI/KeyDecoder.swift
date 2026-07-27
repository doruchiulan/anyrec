/// Turns the bytes a terminal sends into keys, kept apart from the terminal
/// itself so the escape-sequence handling can be exercised without a tty.
enum KeyDecoder {
    /// `next` yields one more byte, or nil once the read times out. A nil result
    /// means nothing the TUI should act on: sequences it does not use are
    /// swallowed rather than reported as the escape key, which would quit.
    static func decode(first byte: UInt8, next: () -> UInt8?) -> Key? {
        switch byte {
        case 0x03: .interrupt
        case 0x0A, 0x0D: .enter
        case 0x1B: escapeSequence(next)
        case 0x7F, 0x08: .backspace
        default: .character(Character(UnicodeScalar(byte)))
        }
    }

    private static func escapeSequence(_ next: () -> UInt8?) -> Key? {
        guard let second = next() else { return .escape }
        guard second == 0x5B else { return nil }
        return controlSequence(next)
    }

    /// A CSI sequence runs to a final byte in 0x40–0x7E; everything before it is
    /// a parameter, and leaving those unread delivers them as keystrokes.
    private static func controlSequence(_ next: () -> UInt8?) -> Key? {
        while let byte = next() {
            if (0x40...0x7E).contains(byte) { return arrow(byte) }
        }
        return nil
    }

    private static func arrow(_ code: UInt8?) -> Key? {
        switch code {
        case 0x41: .up
        case 0x42: .down
        case 0x43: .right
        case 0x44: .left
        default: nil
        }
    }
}
