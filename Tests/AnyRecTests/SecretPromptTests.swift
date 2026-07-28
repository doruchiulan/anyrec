import Testing

@testable import anyrec

@Suite("SecretPrompt")
struct SecretPromptTests {
    /// Enough to tell a paste that landed from one that did not, and no more: the
    /// setup screen is one keystroke away from being shared.
    @Test("shows the tail of a key and hides the rest")
    func masksLongKeys() {
        let masked = SecretPrompt.mask("sk-proj-abcdefghijklmnop")

        #expect(masked.hasSuffix("mnop"))
        #expect(!masked.contains("sk-"))
        #expect(masked.filter { $0 == "•" }.count == 20)
    }

    @Test("hides a short entry completely, where a tail would be most of it")
    func masksShortEntries() {
        #expect(SecretPrompt.mask("sk-abc") == "••••••")
        #expect(SecretPrompt.mask("") == "")
    }

    /// Real keys run past 160 characters; a bar that long would wrap the screen.
    @Test("caps the bullets rather than drawing one per character")
    func capsWidth() {
        let masked = SecretPrompt.mask(String(repeating: "x", count: 200))

        #expect(masked.count == 36)
    }
}
