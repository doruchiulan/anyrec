import Foundation
import Testing

@testable import AnyRecKit

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
            .appendingPathComponent("anyrec-test-\(UUID().uuidString).mp3")
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
    @Test("uploads a stretch of speech as it stands")
    func keepsRegions() {
        #expect(AudioChunks.capped([12..<40, 95..<130]) == [12..<40, 95..<130])
    }

    @Test("splits a region that would outrun the upload limit on its own")
    func capsLongRegions() {
        let parts = AudioChunks.capped([0..<9_000])

        #expect(parts == [0..<3_600, 3_600..<7_200, 7_200..<9_000])
    }

    @Test("names parts in the order they will be sent")
    func names() {
        #expect(AudioChunks.name(0) == "part-000.mp3")
        #expect(AudioChunks.name(12) == "part-012.mp3")
    }
}
