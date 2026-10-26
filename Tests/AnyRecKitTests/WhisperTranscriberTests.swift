import Foundation
import Testing

@testable import AnyRecKit

@Suite("WhisperTranscriber")
struct WhisperTranscriberTests {
    @Test("reads whisper's centisecond segment times as seconds")
    func times() throws {
        let line = try #require(WhisperTranscriber.utterance(from: 1_107, to: 1_696, text: " Sună bine."))
        #expect(line.start == 11.07)
        #expect(line.end == 16.96)
    }

    @Test("trims the leading space whisper puts on every segment, and drops empty ones")
    func text() {
        #expect(WhisperTranscriber.utterance(from: 0, to: 508, text: " Bună ziua.")?.text == "Bună ziua.")
        #expect(WhisperTranscriber.utterance(from: 0, to: 100, text: "   ") == nil)
    }

    @Test("segments arrive unattributed — the service tags them")
    func defaultSpeaker() {
        #expect(WhisperTranscriber.utterance(from: 0, to: 100, text: "x")?.speaker == .others)
    }
}
