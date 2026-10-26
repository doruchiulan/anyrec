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
    public struct Person: Sendable, Equatable, Codable {
        public let name: String
        public var prints: [Voiceprint]

        public init(name: String, prints: [Voiceprint]) {
            self.name = name
            self.prints = prints
        }
    }

    /// Cosine similarity a print has to reach to a person's nearest print before the
    /// name is claimed. Provisional: pyannote clusters one recording at a distance of
    /// 0.70, which is a similarity of 0.30, and naming across recordings should be
    /// stricter than clustering within one. Wrong name is the worse mistake, so the
    /// number only ever moves up until it is measured on real calls.
    public static let threshold: Float = 0.5

    public static let directory = URL(filePath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/anyrec/voices")

    public private(set) var people: [Person]

    public init(people: [Person] = []) {
        self.people = people
    }

    public var names: [String] { people.map(\.name) }
    public var isEmpty: Bool { people.isEmpty }

    /// The closest person, when close enough. Nil leaves the voice a letter.
    public func match(_ print: Voiceprint) -> (name: String, similarity: Float)? {
        let best = people.compactMap { person -> (String, Float)? in
            guard let nearest = person.prints.map({ Self.similarity($0, print) }).max()
            else { return nil }
            return (person.name, nearest)
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

    public func exported() throws -> Data {
        try JSONEncoder().encode(people)
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
            } else {
                let prints = person.prints.filter { !$0.isEmpty }
                guard !prints.isEmpty else { continue }
                people.append(Person(name: name, prints: prints))
                newPeople += 1
                newPrints += prints.count
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
