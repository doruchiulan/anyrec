import Foundation

/// OpenAI's hosted speech-to-text, for people who would rather bring an API key
/// than a local model. The only engine that leaves the machine — the audio is
/// uploaded — so it is never chosen automatically, only by asking for it.
public struct OpenAITranscriber: Transcriber {
    public let name = "openai"
    private let key: String
    private let model: Model

    /// Slack mixes every remote participant into one stream, so telling them apart
    /// is the one thing the separate tracks cannot do. `diarize` is what recovers
    /// them; `whisper` is the older model, kept for when diarisation disappoints.
    public enum Model: String, Sendable, CaseIterable {
        case diarize = "gpt-4o-transcribe-diarize"
        case whisper = "whisper-1"

        /// The diarising model answers in its own format and takes no language hint;
        /// whisper-1 is the only other model here that returns timestamps at all,
        /// and without timestamps there is no conversation to reconstruct.
        var format: String { self == .diarize ? "diarized_json" : "verbose_json" }
        var takesLanguage: Bool { self == .whisper }
        /// It runs its own voice detection server-side, so it wants the call whole:
        /// speaker letters are only consistent within a single request.
        var wantsOneUpload: Bool { self == .diarize }
    }

    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    /// A slow upload on a long call. Well past the point where retrying is better.
    static let timeout: TimeInterval = 600

    public init(key: String? = nil, model: Model = .diarize) throws {
        guard let found = key ?? OpenAIKey.current() else {
            throw TranscriptionError.openAIKeyMissing(OpenAIKey.file)
        }
        self.key = found
        self.model = model
    }

    /// Asks the API whether a key works, so a bad paste is caught now rather than
    /// after the call it was meant to transcribe. Nothing but the key is sent.
    public static func check(_ key: String) async throws {
        var request = URLRequest(
            url: URL(string: "https://api.openai.com/v1/models")!, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenAIKey.Failure.rejected(complaint(data, response))
        }
    }

    public func speech(
        of url: URL, in regions: [Range<TimeInterval>], language: String?
    ) async throws -> Speech {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("anyrec-openai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var utterances: [Utterance] = []
        var heard: String?
        for chunk in try AudioChunks.split(url, speech: spans(regions), into: scratch) {
            let answer = try await send(chunk.url, language: language)
            heard = heard ?? answer.language
            utterances += (answer.segments ?? []).map { segment in
                Utterance(
                    start: segment.start + chunk.start, end: segment.end + chunk.start,
                    text: segment.text,
                    speaker: segment.speaker.map(Speaker.voice) ?? .others
                )
            }
        }
        return Speech(utterances: utterances, language: heard.map(Self.tag))
    }

    /// Leading and trailing silence still goes, because an engine handed room tone
    /// invents sentences to fill it — but the gaps in the middle stay when the model
    /// needs the call in one piece.
    private func spans(_ regions: [Range<TimeInterval>]) -> [Range<TimeInterval>] {
        guard model.wantsOneUpload, let first = regions.first, let last = regions.last
        else { return regions }
        return [first.lowerBound..<last.upperBound]
    }

    private func send(_ audio: URL, language: String?) async throws -> Response {
        var fields = ["model": model.rawValue, "response_format": model.format]
        if model.wantsOneUpload { fields["chunking_strategy"] = "auto" }
        if model.takesLanguage {
            fields["language"] = language.flatMap {
                Locale.Language(identifier: $0).languageCode?.identifier
            }
        }

        let boundary = "anyrec-\(UUID().uuidString)"
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
        /// Only the diarising model fills this in, as "A", "B", and so on.
        let speaker: String?
    }
    let language: String?
    let segments: [Segment]?
}

private struct Failure: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}
