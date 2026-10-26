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
    }

    public static let fileName = "voices.json"

    public var voices: [Voice]

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
    }

    public static func read(_ url: URL) -> RecordingVoices? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordingVoices.self, from: data)
    }

    public static func read(in directory: URL) -> RecordingVoices? {
        TranscriptStore.voicesURL(in: directory).flatMap { read($0) }
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

    /// The names as they stand afterwards, and the files rewritten.
    @discardableResult
    public static func apply(
        _ names: [String: String], in folder: URL
    ) throws -> (voices: RecordingVoices, written: [URL]) {
        try TranscriptStore.pinSelection(in: folder)
        guard let file = TranscriptStore.voicesURL(in: folder), var voices = RecordingVoices.read(file) else {
            throw Failure.nothingToName(folder: folder.lastPathComponent)
        }

        var library = VoiceLibrary.load()
        for (letter, name) in names {
            guard let voice = voices.voices.first(where: { $0.letter == letter }) else {
                throw Failure.noSuchVoice(letter: letter)
            }
            voices.name(letter, name)
            library.enroll(name, voice.print)
        }
        try voices.write(to: file)
        try library.save()

        return (voices, try render(folder, names: voices.names))
    }

    /// Older generations keep their own speaker identities.
    private static func render(_ folder: URL, names: [String: String]) throws -> [URL] {
        let allFiles =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil)) ?? []
        let files = TranscriptStore.selection(in: folder).map { [folder.appendingPathComponent($0.transcript)] } ?? allFiles
        var written: [URL] = []
        for file in files
        where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("transcript-") {
            guard let transcript = Transcript.read(file) else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            written += try TranscriptionService.write(
                transcript, into: folder, named: name, names: names)
        }
        return written
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
