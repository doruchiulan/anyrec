import Testing
@testable import AnyRecBar

@Suite struct SlackComposerTests {
    @Test func verifiesMultilineSlackText() {
        let message = "QA & Doru\n\nMâine la 10\nRecording\nhttps://example.invalid/recording"
        let browser = message.replacingOccurrences(of: "\n", with: "\r\n")
            .replacingOccurrences(of: " la ", with: "\u{00a0}la\u{00a0}") + "\n"
        #expect(SlackComposer.matches(browser, message))
        #expect(!SlackComposer.matches("Synthetic AnyRec draft", message))
        #expect(!SlackComposer.matches(message + "\nAnother draft", message))
        #expect(!SlackComposer.matches(String(message.dropLast(4)), message))
    }
}
