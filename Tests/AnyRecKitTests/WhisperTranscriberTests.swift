import Foundation
import Testing

@testable import AnyRecKit

@Suite("WhisperTranscriber")
struct WhisperTranscriberTests {
    private let output = Data(
        """
        {
          "result": { "language": "ro" },
          "transcription": [
            {
              "offsets": { "from": 0, "to": 5080 },
              "text": " Bună ziua, mulțumesc că ați venit."
            },
            {
              "offsets": { "from": 11070, "to": 16960 },
              "text": " Sună bine."
            }
          ]
        }
        """.utf8)

    @Test("reads whisper's millisecond offsets as seconds")
    func offsets() throws {
        let utterances = try WhisperTranscriber.parse(output)
        #expect(utterances.count == 2)
        #expect(utterances[0].start == 0)
        #expect(utterances[0].end == 5.08)
        #expect(utterances[1].start == 11.07)
    }

    @Test("trims the leading space whisper puts on every segment")
    func trimsText() throws {
        let utterances = try WhisperTranscriber.parse(output)
        #expect(utterances[0].text == "Bună ziua, mulțumesc că ați venit.")
    }

    @Test("segments arrive unattributed — the service tags them")
    func defaultSpeaker() throws {
        #expect(try WhisperTranscriber.parse(output).allSatisfy { $0.speaker == .others })
    }
}
