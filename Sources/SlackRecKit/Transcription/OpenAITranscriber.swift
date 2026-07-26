import Foundation

/// OpenAI's hosted speech-to-text, for people who would rather bring an API key
/// than a local model. The only engine that leaves the machine — the audio is
/// uploaded — so it is never chosen automatically, only by asking for it.
public struct OpenAITranscriber: Transcriber {
    public let name = "openai"
    private let key: String

    /// `whisper-1` is the only model the API returns timestamps for, and without
    /// timestamps the two tracks cannot be interleaved into a conversation. The
    /// newer `gpt-4o-transcribe` models answer with plain text, so they are no use
    /// here however good they are — that is why this is not configurable.
    static let model = "whisper-1"
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    /// A slow upload on a long call. Well past the point where retrying is better.
    static let timeout: TimeInterval = 600

    public static var keyFile: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/slack-rec/openai-key")
    }

    /// The environment first, so a key can be scoped to one shell; the file is for
    /// people who would rather not export a secret into every process they launch.
    public static func key() -> String? {
        [
            ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
            try? String(contentsOf: keyFile, encoding: .utf8),
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
    }

    public init(key: String? = nil) throws {
        guard let found = key ?? Self.key() else {
            throw TranscriptionError.openAIKeyMissing(Self.keyFile)
        }
        self.key = found
    }

    public func speech(of url: URL, language: String?) async throws -> Speech {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("slack-rec-openai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var utterances: [Utterance] = []
        var heard: String?
        for chunk in try AudioChunks.split(url, into: scratch) {
            let answer = try await send(chunk.url, language: language)
            heard = heard ?? answer.language
            utterances += (answer.segments ?? []).map {
                Utterance(
                    start: $0.start + chunk.start, end: $0.end + chunk.start, text: $0.text
                )
            }
        }
        return Speech(utterances: utterances, language: heard.map(Self.tag))
    }

    private func send(_ audio: URL, language: String?) async throws -> Response {
        var fields = ["model": Self.model, "response_format": "verbose_json"]
        fields["language"] = language.flatMap { Locale.Language(identifier: $0).languageCode?.identifier }

        let boundary = "slack-rec-\(UUID().uuidString)"
        var request = URLRequest(url: Self.endpoint, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.body(fields: fields, file: audio, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranscriptionError.engineFailed(engine: name, log: Self.complaint(data, response))
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    static func body(fields: [String: String], file: URL, boundary: String) throws -> Data {
        var body = Data()
        let opening = "--\(boundary)\r\nContent-Disposition: form-data; name="
        for (field, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("\(opening)\"\(field)\"\r\n\r\n\(value)\r\n".utf8))
        }
        let header =
            "\(opening)\"file\"; filename=\"\(file.lastPathComponent)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n"
        body.append(Data(header.utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// The key is never in here: the request headers are not echoed back, and only
    /// the response body reaches the error.
    static func complaint(_ data: Data, _ response: URLResponse) -> String {
        let status = (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "no response"
        let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error.message
        return "\(status) — \(message ?? String(decoding: data.prefix(500), as: UTF8.self))"
    }

    /// whisper-1 answers with the language's English name; everything downstream
    /// speaks ISO codes, and `Transcript` renders the name back from one.
    static func tag(_ name: String) -> String {
        let english = Locale(identifier: "en_US_POSIX")
        let wanted = name.lowercased()
        let match = Locale.LanguageCode.isoLanguageCodes.first {
            english.localizedString(forLanguageCode: $0.identifier)?.lowercased() == wanted
        }
        return match?.identifier ?? name
    }
}

private struct Response: Decodable {
    struct Segment: Decodable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }
    let language: String?
    let segments: [Segment]?
}

private struct Failure: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}
