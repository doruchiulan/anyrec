import Foundation
import Testing

@testable import SlackRecKit

@Suite("OpenAITranscriber")
struct OpenAITranscriberTests {
    @Test("turns the API's language name into the tag the transcript renders from")
    func languageTag() {
        #expect(OpenAITranscriber.tag("english") == "en")
        #expect(OpenAITranscriber.tag("romanian") == "ro")
    }

    @Test("passes an unrecognised language through rather than losing it")
    func unknownLanguage() {
        #expect(OpenAITranscriber.tag("nonesuch") == "nonesuch")
    }

    @Test("builds a multipart body carrying the fields and the file")
    func multipart() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("slack-rec-test-\(UUID().uuidString).mp3")
        try Data("audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let body = try OpenAITranscriber.body(
            fields: ["model": "whisper-1", "language": "ro"], file: file, boundary: "X"
        )
        let text = String(decoding: body, as: UTF8.self)

        #expect(text.contains("name=\"language\"\r\n\r\nro\r\n"))
        #expect(text.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
        #expect(text.contains("filename=\"\(file.lastPathComponent)\""))
        #expect(text.contains("\r\n\r\naudio\r\n--X--\r\n"))
    }

    @Test("reports what the API complained about, and nothing else")
    func failureMessage() {
        let body = Data(#"{"error":{"message":"Incorrect API key provided: sk-abc"}}"#.utf8)
        let response = HTTPURLResponse(
            url: OpenAITranscriber.endpoint, statusCode: 401, httpVersion: nil, headerFields: nil
        )!

        #expect(
            OpenAITranscriber.complaint(body, response)
                == "HTTP 401 — Incorrect API key provided: sk-abc")
    }

    @Test("falls back to the raw body when the failure is not the usual shape")
    func unparseableFailure() {
        let response = HTTPURLResponse(
            url: OpenAITranscriber.endpoint, statusCode: 502, httpVersion: nil, headerFields: nil
        )!

        #expect(OpenAITranscriber.complaint(Data("<html>bad gateway".utf8), response)
            == "HTTP 502 — <html>bad gateway")
    }
}

@Suite("AudioChunks")
struct AudioChunksTests {
    private let directory = URL(fileURLWithPath: "/tmp/parts")

    @Test("reads each part's own start time out of ffmpeg's manifest")
    func manifest() {
        let csv = """
            /tmp/parts/part-000.mp3,0.000000,3600.048000
            /tmp/parts/part-001.mp3,3600.048000,4210.123000

            """

        #expect(
            AudioChunks.parse(csv, in: directory) == [
                AudioChunks.Chunk(url: directory.appendingPathComponent("part-000.mp3"), start: 0),
                AudioChunks.Chunk(
                    url: directory.appendingPathComponent("part-001.mp3"), start: 3_600.048),
            ])
    }

    @Test("resolves parts against the scratch directory, not the recorded path")
    func relocatable() {
        let chunks = AudioChunks.parse("elsewhere/part-000.mp3,0.000000,12.5", in: directory)

        #expect(chunks.first?.url == directory.appendingPathComponent("part-000.mp3"))
    }

    @Test("ignores rows that are not a part")
    func rubbish() {
        #expect(AudioChunks.parse("\n,\nnot a row\n", in: directory).isEmpty)
    }
}
