import Foundation

/// Picks an engine, runs it over the call, and works out who said each line.
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
        public var enabledEngines: Set<TranscriptionEngine>?
        public var diarize: Bool
        /// When the call could hear the microphone, if anything watched. Nil leaves
        /// the microphone alone.
        public var live: MicrophoneLive?

        public init(
            tracks: [Track], engine: TranscriptionEngine = .auto, language: String? = nil,
            model: URL? = nil, diarize: Bool = true, live: MicrophoneLive? = nil
        ) {
            self.tracks = tracks
            self.engine = engine
            self.language = language
            self.model = model
            self.diarize = diarize
            self.live = live
        }
    }

    /// What the engine is pointed at, plus what is needed afterwards to tell the two
    /// sides of the call apart.
    struct Source: Sendable {
        let url: URL
        let regions: [Range<TimeInterval>]
        let microphone: AudioEnvelope?
        let systemAudio: AudioEnvelope?
        /// Set only when there is a single track, where who spoke is not in question.
        let only: Speaker?
        /// How the tracks went into the mix. Nil when there was no mix.
        let mix: MixPlan?
    }

    /// Audio tracks of a recording, microphone first. Empty files are skipped —
    /// a track that was switched off still leaves a zero-length placeholder.
    public static func tracks(in plan: OutputPlan) -> [Track] {
        let separate = [Track(url: plan.microphone, speaker: .me), Track(url: plan.systemAudio, speaker: .others)]
            .filter { hasAudio($0.url) }
        if !separate.isEmpty { return separate }
        let merged = plan.directory.appendingPathComponent("call.mp4")
        return hasAudio(merged) ? [Track(url: merged, speaker: .others)] : []
    }

    /// The transcript, with the far end lettered, and what is known about each letter.
    public struct Transcribed: Sendable {
        public let transcript: Transcript
        /// Nil when the far end was one voice throughout, or nothing told it apart.
        public let voices: RecordingVoices?
    }

    public static func run(
        _ job: Job, progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> Transcribed {
        let source = try prepared(job, progress: progress)
        defer { try? FileManager.default.removeItem(at: source.scratch) }
        return try await transcribe(job, source: source.audio, progress: progress)
    }

    static func prepared(_ job: Job, progress: @Sendable (String) -> Void) throws -> (audio: Source, scratch: URL) {
        guard !job.tracks.isEmpty else { throw TranscriptionError.noAudio }
        guard let ffmpeg = Muxer.ffmpegPath() else { throw TranscriptionError.ffmpegNotFound }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-transcribe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        do { return (try prepare(job, in: scratch, using: ffmpeg, progress: progress), scratch) }
        catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    static func transcribe(_ job: Job, source: Source, progress: @Sendable (String) -> Void) async throws -> Transcribed {
        let transcript = try await recognize(job, source: source, progress: progress)
        let (lines, voices) = await separate(transcript, in: source, useDiarization: job.diarize, progress: progress)
        return Transcribed(transcript: Transcript(utterances: lines, language: transcript.language,
                           engine: transcript.engine, notes: transcript.notes), voices: voices)
    }

    static func recognize(_ job: Job, source: Source, progress: @Sendable (String) -> Void) async throws -> Transcript {
        let language = try language(for: job, of: source.url, progress: progress)
        let transcriber = try await transcriber(for: job, language: language ?? "en")
        progress("Transcribing with \(transcriber.name)…")
        let spoken = try await transcriber.speech(of: source.url, in: source.regions, language: language)
        return Transcript(utterances: attribute(spoken.utterances, in: source,
                          preservingSpeakers: transcriber.name == "openai" && job.diarize),
                          language: language ?? spoken.language, engine: transcriber.name, notes: source.mix?.notes ?? [])
    }

    /// One mixed file is what gets transcribed. Two tracks handed to an engine
    /// separately come back as two timelines, and an engine's timestamps are only
    /// honest about the audio it was given — merging them shuffles the conversation,
    /// which is the whole reason attribution moved out of the file names.
    private static func prepare(
        _ job: Job, in scratch: URL, using ffmpeg: String, progress: @Sendable (String) -> Void
    ) throws -> Source {
        let track = { (speaker: Speaker) in job.tracks.first { $0.speaker == speaker }?.url }
        let microphone = track(.me)
        let systemAudio = track(.others)

        progress("Preparing the audio…")
        guard
            let mix = try AudioMix.build(
                microphone: microphone, systemAudio: systemAudio, live: job.live, into: scratch,
                using: ffmpeg)
        else {
            let single = job.tracks[0]
            return Source(
                url: single.url, regions: speech(in: single.url, using: ffmpeg),
                microphone: nil, systemAudio: nil, only: single.speaker, mix: nil
            )
        }

        return Source(
            url: mix.url, regions: speech(in: mix.url, using: ffmpeg),
            microphone: microphone.flatMap { AudioEnvelope.of($0, using: ffmpeg) },
            systemAudio: systemAudio.flatMap { AudioEnvelope.of($0, using: ffmpeg) },
            only: nil, mix: mix.plan
        )
    }

    private static func speech(in url: URL, using ffmpeg: String) -> [Range<TimeInterval>] {
        AudioEnvelope.of(url, using: ffmpeg).map(SpeechRegions.detect) ?? []
    }

    static func attribute(
        _ utterances: [Utterance], in source: Source, preservingSpeakers: Bool = false
    ) -> [Utterance] {
        guard !preservingSpeakers else { return utterances }
        if let only = source.only {
            return utterances.map {
                var line = $0
                line.speaker = only
                return line
            }
        }
        guard let microphone = source.microphone, let systemAudio = source.systemAudio else {
            return utterances
        }
        return SpeakerAttribution.label(
            utterances, microphone: microphone, systemAudio: systemAudio,
            mix: source.mix ?? .plain)
    }

    /// The written files, in the order they were produced. The Markdown and the
    /// subtitles carry `names`; the data file keeps the letters, so naming can be
    /// redone from it.
    @discardableResult
    public static func write(
        _ transcript: Transcript, into directory: URL, named name: String,
        names: [String: String] = [:]
    ) throws -> [URL] {
        let markdown = directory.appendingPathComponent("\(name).md")
        let subtitles = directory.appendingPathComponent("\(name).srt")
        let data = directory.appendingPathComponent("\(name).json")
        let title = directory.lastPathComponent
        let shown = transcript.named(names)
        try shown.markdown(title: title).write(to: markdown, atomically: true, encoding: .utf8)
        try shown.srt.write(to: subtitles, atomically: true, encoding: .utf8)
        try JSONEncoder().encode(transcript).write(to: data, options: .atomic)
        return [markdown, subtitles, data]
    }

    /// Nil means nobody has decided yet — the remote engines detect as they go, and
    /// running whisper locally first would defeat the point of not having it installed.
    private static func language(
        for job: Job, of mix: URL, progress: @Sendable (String) -> Void
    ) throws -> String? {
        if let language = job.language { return language }
        if job.engine.hearsLanguage { return nil }
        if job.engine == .auto, job.enabledEngines?.contains(.parakeet) != false, ParakeetSetup.isReady { return nil }
        guard job.enabledEngines?.contains(.whisper) != false,
              let whisper = try? WhisperTranscriber(model: job.model) else { return "en" }

        progress("Detecting the language…")
        if let detected = try whisper.detectLanguage(of: mix) { return detected }
        progress("  Could not tell — assuming English. Pass --language to override.")
        return "en"
    }

    private static func transcriber(for job: Job, language: String) async throws -> Transcriber {
        switch job.engine {
        case .parakeet:
            return try ParakeetTranscriber()
        case .whisper:
            return try WhisperTranscriber(model: job.model)
        case .apple:
            return try await appleTranscriber(language: language)
        case .openai:
            return try OpenAITranscriber(model: job.diarize ? .diarize : .whisper)
        case .auto:
            /// Deliberately local-only: `auto` must never start uploading a call
            /// because a model happened to be missing.
            if job.enabledEngines?.contains(.parakeet) != false, let parakeet = try? ParakeetTranscriber() { return parakeet }
            if job.enabledEngines?.contains(.apple) != false, let apple = try? await appleTranscriber(language: language) { return apple }
            guard job.enabledEngines?.contains(.whisper) != false else {
                throw TranscriptionError.engineFailed(engine: "auto", log: "No enabled engine can transcribe this language.")
            }
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
