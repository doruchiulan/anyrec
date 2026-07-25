import Foundation

/// Picks an engine, runs it over each audio track, and interleaves the results.
public enum TranscriptionService {
    public struct Track: Sendable {
        public let url: URL
        public let speaker: Speaker

        public init(url: URL, speaker: Speaker) {
            self.url = url
            self.speaker = speaker
        }
    }

    public struct Job: Sendable {
        public var tracks: [Track]
        public var engine: TranscriptionEngine
        public var language: String?
        public var model: URL?

        public init(
            tracks: [Track], engine: TranscriptionEngine = .auto, language: String? = nil,
            model: URL? = nil
        ) {
            self.tracks = tracks
            self.engine = engine
            self.language = language
            self.model = model
        }
    }

    /// Audio tracks of a recording, microphone first. Empty files are skipped —
    /// a track that was switched off still leaves a zero-length placeholder.
    public static func tracks(in plan: OutputPlan) -> [Track] {
        [Track(url: plan.microphone, speaker: .me), Track(url: plan.systemAudio, speaker: .others)]
            .filter { hasAudio($0.url) }
    }

    public static func run(
        _ job: Job, progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> Transcript {
        guard !job.tracks.isEmpty else { throw TranscriptionError.noAudio }

        let language = try language(for: job, progress: progress)
        let transcriber = try await transcriber(for: job, language: language)
        progress("Transcribing with \(transcriber.name) (\(language))…")

        var utterances: [Utterance] = []
        for track in job.tracks {
            progress("  \(track.url.lastPathComponent)…")
            let spoken = try await transcriber.utterances(of: track.url, language: language)
            utterances += spoken.map {
                var tagged = $0
                tagged.speaker = track.speaker
                return tagged
            }
        }
        return Transcript(utterances: utterances, language: language, engine: transcriber.name)
    }

    /// The written files, in the order they were produced.
    @discardableResult
    public static func write(
        _ transcript: Transcript, into directory: URL, named name: String
    ) throws -> [URL] {
        let markdown = directory.appendingPathComponent("\(name).md")
        let subtitles = directory.appendingPathComponent("\(name).srt")
        let title = directory.lastPathComponent
        try transcript.markdown(title: title).write(to: markdown, atomically: true, encoding: .utf8)
        try transcript.srt.write(to: subtitles, atomically: true, encoding: .utf8)
        return [markdown, subtitles]
    }

    /// Detection reads the opening of the fullest track: AAC compresses silence to
    /// almost nothing, so the largest file is the one with the most speech in it.
    private static func language(
        for job: Job, progress: @Sendable (String) -> Void
    ) throws -> String {
        if let language = job.language { return language }
        guard let whisper = try? WhisperTranscriber(model: job.model) else { return "en" }

        progress("Detecting the language…")
        for track in job.tracks.sorted(by: { size(of: $0.url) > size(of: $1.url) }) {
            if let detected = try whisper.detectLanguage(of: track.url) { return detected }
        }
        progress("  Could not tell — assuming English. Pass --language to override.")
        return "en"
    }

    private static func transcriber(for job: Job, language: String) async throws -> Transcriber {
        switch job.engine {
        case .whisper:
            return try WhisperTranscriber(model: job.model)
        case .apple:
            return try await appleTranscriber(language: language)
        case .auto:
            if let apple = try? await appleTranscriber(language: language) { return apple }
            return try WhisperTranscriber(model: job.model)
        }
    }

    private static func appleTranscriber(language: String) async throws -> Transcriber {
        guard #available(macOS 26, *), AppleTranscriber.isAvailable else {
            throw TranscriptionError.appleUnavailable
        }
        guard let locale = await AppleTranscriber.locale(for: language) else {
            throw TranscriptionError.unsupportedLanguage(engine: "apple", language: language)
        }
        return try AppleTranscriber(locale: locale)
    }

    private static func hasAudio(_ url: URL) -> Bool { size(of: url) > 1_024 }

    private static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
