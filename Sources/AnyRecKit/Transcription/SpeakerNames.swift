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
        /// The owner gave this name, in the Speakers panel, the terminal or `anyrec speakers`.
        /// Nil in files written before this was recorded, which read as they always did.
        public var namedByOwner: Bool?
        /// What the owner's naming filed in the voice library, so it can be taken back when
        /// the voice is renamed or given away. Nil in files written before this was kept,
        /// and for a voice nobody named.
        public var filed: Filing?

        /// The saved name a voice's print went under when it was named, whether the record
        /// was made by that naming, and the call window's name the naming filed as that
        /// person's alias.
        public struct Filing: Sendable, Equatable, Codable {
            public let person: String
            public let createdPerson: Bool
            public let alias: String?

            public init(person: String, createdPerson: Bool, alias: String? = nil) {
                self.person = person
                self.createdPerson = createdPerson
                self.alias = alias
            }
        }

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
            voice.namedByOwner = namedByOwner
            voice.filed = filed
            return voice
        }
    }

    /// The diarizer heard the person recording as a voice of the far end, and its lines
    /// were given back: to the person a call window showed instead where it showed only
    /// them, to "Me" where the microphone was live and either carried speech or the call
    /// window showed the owner, and to the call otherwise.
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

    /// The owner names a voice. What the call window and the library said is kept, so the
    /// names they offered can still be chosen from later, but no longer counts as a conflict.
    public mutating func name(_ letter: String, _ name: String) {
        guard let index = voices.firstIndex(where: { $0.letter == letter }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        voices[index].name = name.isEmpty ? nil : name
        voices[index].namedByOwner = name.isEmpty ? nil : true
        voices[index].identityEvidence?.conflict = false
    }

    /// The voice no longer carries a name: every line of it went to someone else.
    mutating func unname(_ letter: String) {
        guard let index = voices.firstIndex(where: { $0.letter == letter }) else { return }
        voices[index].name = nil
        voices[index].namedByOwner = nil
        voices[index].filed = nil
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
    /// read as the names. `learnCallName` files the display name the call window showed for
    /// the voice as the named person's alias; it is false when the owner picked someone
    /// other than the person the call window showed. `people` maps a letter to the saved
    /// name of the library person it was picked as, so the print joins that person's even
    /// when the name shown is not one only they answer to; letters without one are filed by
    /// name, as `VoiceLibrary.enroll` resolves it.
    ///
    /// Renaming a voice the owner named takes back what the earlier naming filed first
    /// (`takeBack`), so a wrong pick does not go on matching this voice to that person.
    @discardableResult
    public static func apply(
        _ names: [String: String], in folder: URL, library libraryDirectory: URL = VoiceLibrary.directory,
        learnCallName: Bool = true, people: [String: String] = [:]
    ) throws -> (voices: RecordingVoices, written: [URL]) {
        guard var voices = RecordingVoices.read(in: folder) else {
            throw Failure.nothingToName(folder: folder.lastPathComponent)
        }
        var library = VoiceLibrary.load(from: libraryDirectory)
        let origin = VoiceLibrary.PrintOrigin(recording: OutputPlan(directory: folder).directory.lastPathComponent)
        var emptied: [String] = []
        for (letter, name) in names {
            guard let index = voices.voices.firstIndex(where: { $0.letter == letter }) else {
                throw Failure.noSuchVoice(letter: letter)
            }
            let voice = voices.voices[index]
            let made = takeBack(voice, from: &library)
            voices.name(letter, name)
            let filing = library.file(people[letter] ?? name, voice.print, origin: origin)
            let filed = filing?.name
                ?? people[letter] ?? library.person(answering: name)?.name ?? name.trimmingCharacters(in: .whitespacesAndNewlines)
            /// The display name the call window showed for this voice is now known to
            /// belong to the person just named, under the saved name the print went to.
            var alias: String?
            if learnCallName, let display = voice.identityEvidence?.callName, library.addAlias(display, to: filed) {
                alias = display
            }
            /// Named again as the person an earlier naming made: still that naming's record.
            voices.voices[index].filed = filing.map {
                RecordingVoices.Voice.Filing(person: $0.name, createdPerson: $0.created || made == $0.name, alias: alias)
            }
            if let made, made != filing?.name { emptied.append(made) }
        }
        for name in emptied { library.removeIfEmpty(name) }
        let renamed = voices
        let written = try TranscriptStore.updateSpeakers(in: folder) { layer, _ in layer.voices = renamed }
        try library.save(to: libraryDirectory)
        return (voices, written)
    }

    /// Takes back what the owner's naming of `voice` filed: its print out of the person it
    /// went to — that exact print, never one from another recording — and the alias the
    /// naming added. A voice named before this was recorded (`namedByOwner` with no
    /// `filed`) is looked up by its name, and only its exact print is removed. Returns the
    /// saved name of a record that naming made, which the caller removes once nothing is
    /// left in it (`VoiceLibrary.removeIfEmpty`); a person who existed before is kept even
    /// when empty, because the owner may have typed them on purpose.
    @discardableResult
    static func takeBack(_ voice: RecordingVoices.Voice, from library: inout VoiceLibrary) -> String? {
        if let filed = voice.filed {
            library.retract(voice.print, from: filed.person, alias: filed.alias)
            return filed.createdPerson ? filed.person : nil
        }
        guard voice.namedByOwner == true, let name = voice.name,
              let person = library.people.first(where: { $0.name == name }) ?? library.person(answering: name)
        else { return nil }
        library.retract(voice.print, from: person.name)
        return nil
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
        /// Kept in order and whole: line indexes are how the app and the speakers layer
        /// point at a line.
        return Transcript(keeping: renamed, language: language, engine: engine, notes: notes)
    }
}
