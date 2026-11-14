import Foundation
import UniformTypeIdentifiers

/// A voice reduced to a point: the embedding a speaker model gives a stretch of one
/// person talking, which lands near the same person's other stretches and far from
/// everyone else's. What matching compares.
public typealias Voiceprint = [Float]

/// The people anyrec has been told the names of, kept as voiceprints on disk so the
/// next call can name them without asking. One file per person, several prints each,
/// because a voice on a headset and the same voice on a laptop in a kitchen are two
/// points, and the library should hold both.
///
/// Nothing in here ever leaves the machine. Twenty people is twenty files.
public struct VoiceLibrary: Sendable, Equatable {
    /// One person: the name the owner gave, the display names call windows showed for
    /// them, their prints, and whether this is the person recording. Files written before
    /// aliases and the owner flag existed read with neither.
    public struct Person: Sendable, Equatable, Codable {
        public let name: String
        public var prints: [Voiceprint]
        /// Display names seen in call windows for this person ("Alex Smith" for "Alex").
        /// Learned when a call window and a voiceprint agree; never a source of prints.
        public var aliases: [String]
        public var isOwner: Bool

        public init(name: String, prints: [Voiceprint], aliases: [String] = [], isOwner: Bool = false) {
            self.name = name
            self.prints = prints
            self.aliases = aliases
            self.isOwner = isOwner
        }

        private enum CodingKeys: String, CodingKey { case name, prints, aliases, isOwner }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            prints = try values.decodeIfPresent([Voiceprint].self, forKey: .prints) ?? []
            aliases = try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
            isOwner = try values.decodeIfPresent(Bool.self, forKey: .isOwner) ?? false
        }

        /// Whether `display` is this person: their saved name or one of their aliases,
        /// compared without case or repeated spaces.
        public func answers(to display: String) -> Bool {
            let key = VoiceLibrary.normalized(display)
            return VoiceLibrary.normalized(name) == key || aliases.contains { VoiceLibrary.normalized($0) == key }
        }
    }

    /// Cosine similarity a print has to reach to a person's nearest print before the
    /// name is claimed. Provisional: pyannote clusters one recording at a distance of
    /// 0.70, which is a similarity of 0.30, and naming across recordings should be
    /// stricter than clustering within one. Wrong name is the worse mistake, so the
    /// number only ever moves up until it is measured on real calls.
    public static let threshold: Float = 0.5

    /// `ANYREC_VOICE_LIBRARY` points it elsewhere, so a replay against copies of real
    /// recordings can run without writing into the owner's library.
    public static let directory: URL = {
        if let override = ProcessInfo.processInfo.environment["ANYREC_VOICE_LIBRARY"], !override.isEmpty {
            return URL(filePath: override.expandingTilde)
        }
        return URL(filePath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/anyrec/voices")
    }()

    public private(set) var people: [Person]

    public init(people: [Person] = []) {
        self.people = people
    }

    public var names: [String] { people.map(\.name) }
    public var isEmpty: Bool { people.isEmpty }
    public var owner: Person? { people.first(where: \.isOwner) }

    /// The person a call window's display name belongs to, by saved name or alias. Nil when
    /// nobody, or more than one person, answers to it.
    public func person(answering display: String) -> Person? {
        let matches = people.filter { $0.answers(to: display) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Records a display name a call window showed for `name`. Nothing is added when the
    /// display name already belongs to someone else, and no print is ever added here.
    @discardableResult
    public mutating func addAlias(_ display: String, to name: String) -> Bool {
        let display = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty, let index = people.firstIndex(where: { $0.name == name }),
              !people.contains(where: { $0.name != name && $0.answers(to: display) }) else { return false }
        guard !people[index].answers(to: display) else { return false }
        people[index].aliases.append(display)
        return true
    }

    /// Marks who is recording. One owner at most; nil clears it.
    public mutating func setOwner(_ name: String?) {
        for index in people.indices { people[index].isOwner = people[index].name == name }
    }

    static func normalized(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// The closest person, when close enough. Nil leaves the voice a letter.
    public func match(_ print: Voiceprint) -> (name: String, similarity: Float)? {
        matchPerson(print).map { ($0.person.name, $0.similarity) }
    }

    public func matchPerson(_ print: Voiceprint) -> (person: Person, similarity: Float)? {
        let best = people.compactMap { person -> (Person, Float)? in
            guard let nearest = person.prints.map({ Self.similarity($0, print) }).max()
            else { return nil }
            return (person, nearest)
        }
        .max { $0.1 < $1.1 }
        guard let best, best.1 >= Self.threshold else { return nil }
        return best
    }

    /// A print filed under a name that already exists joins that person's prints.
    public mutating func enroll(_ name: String, _ print: Voiceprint) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !print.isEmpty else { return }
        if let index = people.firstIndex(where: { $0.name == name }) {
            people[index].prints.append(print)
        } else {
            people.append(Person(name: name, prints: [print]))
        }
    }

    public mutating func forget(_ name: String) {
        people.removeAll { $0.name == name }
    }

    public static func similarity(_ a: Voiceprint, _ b: Voiceprint) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    // MARK: - Shared

    /// The library as one file to hand to a colleague: the same people, the same prints,
    /// JSON. Nothing in it is audio — a print is a point, not a recording.
    public static let fileExtension = "anyrecvoices"
    public static var contentType: UTType {
        UTType(filenameExtension: fileExtension, conformingTo: .json) ?? .json
    }

    /// Who is recording is this library's fact, not the colleague's, so it stays behind.
    public func exported() throws -> Data {
        try JSONEncoder().encode(people.map { Person(name: $0.name, prints: $0.prints, aliases: $0.aliases) })
    }

    /// Takes a colleague's file in: a name already here gains the prints it did not
    /// have, a new name is added whole. Returns how many people were new and how many
    /// prints were added, for the sentence that says what happened.
    @discardableResult
    public mutating func merge(_ data: Data) throws -> (people: Int, prints: Int) {
        let incoming = try JSONDecoder().decode([Person].self, from: data)
        var newPeople = 0
        var newPrints = 0
        for person in incoming {
            let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if let index = people.firstIndex(where: { $0.name == name }) {
                for print in person.prints where !people[index].prints.contains(print) {
                    people[index].prints.append(print)
                    newPrints += 1
                }
                for alias in person.aliases { addAlias(alias, to: name) }
            } else {
                let prints = person.prints.filter { !$0.isEmpty }
                guard !prints.isEmpty else { continue }
                /// Whoever exported the file was its owner, not this library's.
                people.append(Person(name: name, prints: prints))
                newPeople += 1
                newPrints += prints.count
                for alias in person.aliases { addAlias(alias, to: name) }
            }
        }
        people.sort { $0.name < $1.name }
        return (newPeople, newPrints)
    }

    // MARK: - On disk

    /// `<directory>/<name>.json`, one person each, so a person can be removed by
    /// deleting a file and the folder reads as a list of who is known.
    public static func load(from directory: URL = directory) -> VoiceLibrary {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        let people = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Person? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(Person.self, from: data)
            }
            .sorted { $0.name < $1.name }
        return VoiceLibrary(people: people)
    }

    public func save(to directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = Set(
            ((try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" })
        var kept: Set<URL> = []
        for person in people {
            let url = directory.appendingPathComponent(Self.fileName(for: person.name))
            try JSONEncoder().encode(person).write(to: url, options: .atomic)
            kept.insert(url.standardizedFileURL)
        }
        for url in existing where !kept.contains(url.standardizedFileURL) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A name is a file name, so what a file system refuses is dropped from it.
    static func fileName(for name: String) -> String {
        let safe = name.map { "/:\\".contains($0) ? "-" : $0 }
        return String(safe) + ".json"
    }
}
