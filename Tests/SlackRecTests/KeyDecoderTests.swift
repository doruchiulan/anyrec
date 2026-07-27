import Testing

@testable import slack_rec

@Suite("KeyDecoder")
struct KeyDecoderTests {
    /// Feeds bytes in order, then dries up the way a timed-out read does.
    private func decode(_ bytes: [UInt8]) -> Key? {
        var rest = bytes.dropFirst()
        return KeyDecoder.decode(first: bytes[0]) {
            defer { rest = rest.dropFirst() }
            return rest.first
        }
    }

    @Test("reads the arrow keys")
    func arrows() {
        #expect(decode([0x1B, 0x5B, 0x41]) == .up)
        #expect(decode([0x1B, 0x5B, 0x42]) == .down)
        #expect(decode([0x1B, 0x5B, 0x43]) == .right)
        #expect(decode([0x1B, 0x5B, 0x44]) == .left)
    }

    @Test("ignores SS3, which only a wheel should be sending")
    func applicationCursorArrows() {
        #expect(decode([0x1B, 0x4F, 0x41]) == nil)
        #expect(decode([0x1B, 0x4F, 0x42]) == nil)
    }

    @Test("ignores a mouse report instead of quitting on it")
    func mouseReport() {
        #expect(decode(Array("\u{1B}[<64;30;12M".utf8)) == nil)
    }

    @Test("ignores a focus change instead of quitting on it")
    func focusChange() {
        #expect(decode(Array("\u{1B}[I".utf8)) == nil)
        #expect(decode(Array("\u{1B}[O".utf8)) == nil)
    }

    @Test("swallows a sequence whole, leaving no parameters behind")
    func consumesParameters() {
        var rest = Array("[<64;30;12M".utf8)[...]
        _ = KeyDecoder.decode(first: 0x1B) {
            defer { rest = rest.dropFirst() }
            return rest.first
        }
        #expect(rest.isEmpty)
    }

    @Test("still reports a lone escape key")
    func loneEscape() {
        #expect(decode([0x1B]) == .escape)
    }

    @Test("reads the keys the screens bind")
    func plainKeys() {
        #expect(decode([0x03]) == .interrupt)
        #expect(decode([0x0D]) == .enter)
        #expect(decode([0x0A]) == .enter)
        #expect(decode([0x7F]) == .backspace)
        #expect(decode([0x71]) == .character("q"))
    }
}
