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
    /// Where one print came from: the recording whose voice was named, or nil for a print
    /// that arrived in an imported `.anyrecvoices` file, and when it was filed. Prints
    /// filed before this was kept have none, and are shown as earlier.
    public struct PrintOrigin: Sendable, Equatable, Codable {
        /// The recording folder's name (`rec-YYYY-MM-DD-HHMMSS`); nil for an import.
        public let recording: String?
        public let filed: Date

        public init(recording: String?, filed: Date = Date()) {
            self.recording = recording
            self.filed = filed
        }

        /// When the recording started, read from its folder's name.
        public var recordingStarted: Date? { recording.flatMap(OutputPlan.date(fromFolderName:)) }
    }

    /// One person: the name the owner gave, the display names call windows showed for
    /// them, their prints, and whether this is the person recording. Files written before
    /// aliases and the owner flag existed read with neither.
    public struct Person: Sendable, Equatable, Codable {
        public let name: String
        /// Changed only through the library, so `origins` stays beside it.
        public internal(set) var prints: [Voiceprint]
        /// Where each print came from, by index; shorter than `prints` (or nil entries) for
        /// prints filed before this was kept. Read through `origin(ofPrint:)`.
        public internal(set) var origins: [PrintOrigin?]
        /// Display names seen in call windows for this person ("Alex Smith" for "Alex").
        /// Learned when a call window and a voiceprint agree; never a source of prints.
        public var aliases: [String]
        public var isOwner: Bool
        /// The display name a call window showed for this person most recently. Transcripts
        /// written from then on call them this rather than the saved name, which stays the
        /// key the library is filed and matched under.
        public var displayName: String?

        public init(name: String, prints: [Voiceprint], aliases: [String] = [], isOwner: Bool = false,
                    displayName: String? = nil, origins: [PrintOrigin?] = []) {
            self.name = name
            self.prints = prints
            self.origins = Self.trimmed(origins)
            self.aliases = aliases
            self.isOwner = isOwner
            self.displayName = displayName
        }

        /// Where print `index` came from; nil when that was not kept.
        public func origin(ofPrint index: Int) -> PrintOrigin? {
            origins.indices.contains(index) ? origins[index] : nil
        }

        /// Nothing left that could name anyone: no print to match and no other name.
        var isEmpty: Bool { prints.isEmpty && aliases.isEmpty && displayName == nil && !isOwner }

        mutating func add(_ print: Voiceprint, origin: PrintOrigin?) {
            alignOrigins()
            prints.append(print)
            origins.append(origin)
            origins = Self.trimmed(origins)
        }

        mutating func removePrint(at index: Int) {
            alignOrigins()
            prints.remove(at: index)
            origins.remove(at: index)
            origins = Self.trimmed(origins)
        }

        private mutating func alignOrigins() {
            if origins.count < prints.count { origins += Array(repeating: nil, count: prints.count - origins.count) }
            if origins.count > prints.count { origins.removeLast(origins.count - prints.count) }
        }

        /// One spelling for "not known": no trailing nils, so a person compares equal to
        /// itself read back from disk.
        private static func trimmed(_ origins: [PrintOrigin?]) -> [PrintOrigin?] {
            var origins = origins
            while let last = origins.last, last == nil { origins.removeLast() }
            return origins
        }

        /// What a transcript calls this person: the call window's name once one is known.
        public var shownName: String { displayName ?? name }

        private enum CodingKeys: String, CodingKey { case name, prints, origins, aliases, isOwner, displayName }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            prints = try values.decodeIfPresent([Voiceprint].self, forKey: .prints) ?? []
            origins = Self.trimmed(try values.decodeIfPresent([PrintOrigin?].self, forKey: .origins) ?? [])
            aliases = try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
            isOwner = try values.decodeIfPresent(Bool.self, forKey: .isOwner) ?? false
            displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
        }

        /// `origins` is written only once a print has one, so a library that never filed a
        /// print since keeps its files' shape.
        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(name, forKey: .name)
            try values.encode(prints, forKey: .prints)
            if origins.contains(where: { $0 != nil }) { try values.encode(origins, forKey: .origins) }
            try values.encode(aliases, forKey: .aliases)
            try values.encode(isOwner, forKey: .isOwner)
            try values.encodeIfPresent(displayName, forKey: .displayName)
        }

        /// Whether `display` is this person: their saved name or one of their aliases,
        /// compared without case or repeated spaces.
        public func answers(to display: String) -> Bool {
            let key = VoiceLibrary.normalized(display)
            return VoiceLibrary.normalized(name) == key || aliases.contains { VoiceLibrary.normalized($0) == key }
                || displayName.map { VoiceLibrary.normalized($0) == key } == true
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

    /// Records that a call window showed `display` for `name`: filed as an alias when it is
    /// new, and kept as the name transcripts use for this person from now on. Nothing
    /// changes when the display name belongs to someone else, or is only the saved name
    /// written differently.
    @discardableResult
    public mutating func noteCallName(_ display: String, for name: String) -> Bool {
        let display = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty, let index = people.firstIndex(where: { $0.name == name }),
              !people.contains(where: { $0.name != name && $0.answers(to: display) }),
              Self.normalized(display) != Self.normalized(name) else { return false }
        var changed = false
        if !people[index].answers(to: display) {
            people[index].aliases.append(display)
            changed = true
        }
        if people[index].displayName != display {
            people[index].displayName = display
            changed = true
        }
        return changed
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

    /// A print filed under a name somebody already answers to joins that person's prints:
    /// their saved name first, else the one person whose alias or display name it is.
    /// Typing the name a transcript shows ("Andrei Lungu" for someone saved as "Andi")
    /// must not start a second record for the same person. A print the person already has
    /// is not added twice. Returns the saved name the print was filed under, nil when
    /// nothing was filed; `file` also says whether the record was made for it.
    @discardableResult
    public mutating func enroll(_ name: String, _ print: Voiceprint, origin: PrintOrigin? = nil) -> String? {
        file(name, print, origin: origin)?.name
    }

    @discardableResult
    public mutating func file(_ name: String, _ print: Voiceprint, origin: PrintOrigin? = nil) -> (name: String, created: Bool)? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !print.isEmpty else { return nil }
        if let index = people.firstIndex(where: { $0.name == name })
            ?? person(answering: name).flatMap({ found in people.firstIndex { $0.name == found.name } }) {
            if !people[index].prints.contains(print) { people[index].add(print, origin: origin) }
            return (people[index].name, false)
        }
        people.append(Person(name: name, prints: [print], origins: [origin]))
        return (name, true)
    }

    /// Takes back what naming one voice filed under `name`: that exact print, when the
    /// person still has it, and the alias the same naming added. Prints that came from
    /// anywhere else are left alone. Returns whether anything changed. The record itself
    /// stays; `removeIfEmpty` is for a record that naming made.
    @discardableResult
    public mutating func retract(_ print: Voiceprint, from name: String, alias: String? = nil) -> Bool {
        guard let index = people.firstIndex(where: { $0.name == name }) else { return false }
        var changed = false
        if !print.isEmpty, let at = people[index].prints.firstIndex(of: print) {
            people[index].removePrint(at: at)
            changed = true
        }
        if let alias, let at = people[index].aliases.firstIndex(of: alias) {
            people[index].aliases.remove(at: at)
            changed = true
        }
        return changed
    }

    /// Removes a person who has nothing left to be recognised by: no print, no alias, no
    /// call-window name, not the owner.
    @discardableResult
    public mutating func removeIfEmpty(_ name: String) -> Bool {
        guard let index = people.firstIndex(where: { $0.name == name }), people[index].isEmpty else { return false }
        people.remove(at: index)
        return true
    }

    /// One print the owner says is wrong, out of one person's record. The person stays.
    public mutating func removePrint(at index: Int, from name: String) {
        guard let person = people.firstIndex(where: { $0.name == name }),
              people[person].prints.indices.contains(index) else { return }
        people[person].removePrint(at: index)
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
    /// The type macOS gives a `.anyrecvoices` file. Nothing declares the extension, so this
    /// is a dynamic type. It must be asked for without `conformingTo:`: that produces a
    /// different dynamic identifier from the one Finder assigns, so the open panel greyed
    /// out every voices file.
    public static var contentType: UTType {
        UTType(filenameExtension: fileExtension) ?? .json
    }

    /// What the import panel accepts: voices files, plus plain JSON, because a file sent
    /// through mail or chat sometimes arrives with `.json` added or swapped in.
    public static var importTypes: [UTType] { [contentType, .json] }

    /// Who is recording is this library's fact, not the colleague's, so it stays behind.
    public func exported() throws -> Data {
        try JSONEncoder().encode(people.map {
            Person(name: $0.name, prints: $0.prints, aliases: $0.aliases, displayName: $0.displayName)
        })
    }

    /// Takes a colleague's file in. A person already here gains the prints they did not
    /// have; anyone else is added whole. "Already here" means the same saved name or, when
    /// that misses, someone here answering to the incoming name, an alias or the display
    /// name. Their "Andi" is my "Andrei Lungu", and adding a second record would split
    /// one voice across two people. Returns how many people were new and how many prints
    /// were added, for the sentence that says what happened.
    @discardableResult
    public mutating func merge(_ data: Data) throws -> (people: Int, prints: Int) {
        let incoming = try JSONDecoder().decode([Person].self, from: data)
        let imported = PrintOrigin(recording: nil)
        var newPeople = 0
        var newPrints = 0
        for person in incoming {
            let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if let index = people.firstIndex(where: { $0.name == name }) ?? existing(answeringAnyNameOf: person) {
                let saved = people[index].name
                if saved != name { addAlias(name, to: saved) }
                for print in person.prints where !people[index].prints.contains(print) && !print.isEmpty {
                    people[index].add(print, origin: imported)
                    newPrints += 1
                }
                for alias in person.aliases { addAlias(alias, to: saved) }
                if people[index].displayName == nil, let shown = person.displayName { noteCallName(shown, for: saved) }
            } else {
                let prints = person.prints.filter { !$0.isEmpty }
                guard !prints.isEmpty else { continue }
                /// Whoever exported the file was its owner, not this library's.
                people.append(Person(name: name, prints: prints, origins: prints.map { _ in imported }))
                newPeople += 1
                newPrints += prints.count
                for alias in person.aliases { addAlias(alias, to: name) }
                if let shown = person.displayName { noteCallName(shown, for: name) }
            }
        }
        people.sort { $0.name < $1.name }
        return (newPeople, newPrints)
    }

    /// The one person here who answers to any of `person`'s names. Nil when nobody does,
    /// or when the names point at more than one person.
    private func existing(answeringAnyNameOf person: Person) -> Int? {
        let names = [person.name] + person.aliases + [person.displayName].compactMap { $0 }
        let matches = Set(names.compactMap { self.person(answering: $0)?.name })
        guard matches.count == 1, let name = matches.first else { return nil }
        return people.firstIndex { $0.name == name }
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
