import Foundation

public struct RecordingVoices: Sendable, Equatable, Codable {
    public struct Voice: Sendable, Equatable, Codable {
        public let letter: String
        public let print: Voiceprint
        /// The longest thing this voice said, for the dialog that asks who it is.
        public let sample: String
        public let start: TimeInterval
        public let end: TimeInterval
        /// Nil until someone says, or a voiceprint in the library matches.
        public var name: String?
        public var identityEvidence: SpeakerIdentityEvidence?
        /// The share of this voice's diarized speech that fell inside lines measured as the
        /// microphone's. Near one, the voice is the person recording.
        public var microphoneShare: Double?
        /// How many seconds of it that was.
        public var microphoneSeconds: Double?

        public init(
            letter: String, print: Voiceprint, sample: String, start: TimeInterval,
            end: TimeInterval, name: String? = nil
        ) {
            self.letter = letter
            self.print = print
            self.sample = sample
            self.start = start
            self.end = end
            self.name = name
        }

        func relettered(_ letter: String) -> Voice {
            var voice = Voice(letter: letter, print: print, sample: sample, start: start, end: end, name: name)
            voice.identityEvidence = identityEvidence
            voice.microphoneShare = microphoneShare
            voice.microphoneSeconds = microphoneSeconds
            return voice
        }
    }

    /// The diarizer heard the person recording as a voice of the far end, and its lines
    /// were given back: to "Me" where the microphone was live and carrying speech, to the
    /// person a call window showed instead where it showed one, and to the call otherwise.
    public struct OwnerMerge: Codable, Equatable, Sendable {
        public enum Evidence: String, Codable, Sendable { case microphone, voiceprint, callWindow }
        public let evidence: [Evidence]
        public let toMe: Int
        public let toOthers: Int
    }

    public static let fileName = "voices.json"

    public var voices: [Voice]
    public var ownerMerge: OwnerMerge?
    /// Lines no diarized voice covered that the call window's speaking indicator put a
    /// voice of this recording to.
    public var callLinesNamed: Int?

    public init(voices: [Voice]) {
        self.voices = voices
    }

    public var unnamed: [Voice] { voices.filter { $0.name == nil } }

    /// Letter → name, for everything that has one.
    public var names: [String: String] {
        Dictionary(uniqueKeysWithValues: voices.compactMap { voice in
            voice.name.map { (voice.letter, $0) }
        })
    }

    public mutating func name(_ letter: String, _ name: String) {
        guard let index = voices.firstIndex(where: { $0.letter == letter }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        voices[index].name = name.isEmpty ? nil : name
        voices[index].identityEvidence = nil
    }

    public static func read(_ url: URL) -> RecordingVoices? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordingVoices.self, from: data)
    }

    /// The selected transcript's voices, from its speakers layer or an older generation's file.
    public static func read(in directory: URL) -> RecordingVoices? {
        RecordingTranscript.read(in: directory)?.voices
    }

    public func write(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

public enum VoiceNaming {
    public enum Failure: Error, LocalizedError, CustomStringConvertible {
        case nothingToName(folder: String)
        case noSuchVoice(letter: String)

        public var description: String {
            switch self {
            case .nothingToName(let folder):
                "No speaker voices found in \(folder)."
            case .noSuchVoice(let letter):
                "There is no Speaker \(letter) in this recording."
            }
        }

        public var errorDescription: String? { description }
    }

    /// The names as they stand afterwards, and the files rewritten. Changes the speakers
    /// layer and the library, and re-renders; the summary is not touched — its labels now
    /// read as the names.
    @discardableResult
    public static func apply(
        _ names: [String: String], in folder: URL, library libraryDirectory: URL = VoiceLibrary.directory
    ) throws -> (voices: RecordingVoices, written: [URL]) {
        guard var voices = RecordingVoices.read(in: folder) else {
            throw Failure.nothingToName(folder: folder.lastPathComponent)
        }
        var library = VoiceLibrary.load(from: libraryDirectory)
        for (letter, name) in names {
            guard let voice = voices.voices.first(where: { $0.letter == letter }) else {
                throw Failure.noSuchVoice(letter: letter)
            }
            voices.name(letter, name)
            library.enroll(name, voice.print)
            /// The display name the call window showed for this voice is now known to
            /// belong to the person just named.
            if let display = voice.identityEvidence?.callName { library.addAlias(display, to: name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let renamed = voices
        let written = try TranscriptStore.updateSpeakers(in: folder) { layer, _ in layer.voices = renamed }
        try library.save(to: libraryDirectory)
        return (voices, written)
    }
}

extension Transcript {
    /// The same transcript with every lettered voice that has a name carrying it.
    public func named(_ names: [String: String]) -> Transcript {
        guard !names.isEmpty else { return self }
        let renamed = utterances.map { utterance -> Utterance in
            guard case .voice(let letter) = utterance.speaker, let name = names[letter]
            else { return utterance }
            var line = utterance
            line.speaker = .named(name)
            return line
        }
        return Transcript(utterances: renamed, language: language, engine: engine, notes: notes)
    }
}
