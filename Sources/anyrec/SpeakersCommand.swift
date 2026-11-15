import ArgumentParser
import Foundation
import AnyRecKit

struct Speakers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speakers",
        abstract: "Put names to the voices in a transcript, and remember them for next time.",
        discussion: """
        A transcript whose far end was told apart labels it Speaker A, Speaker B and \
        so on. This lists each letter with a few short clips of it and the names worth \
        choosing — who the call window showed, saved voices that match or sound close, \
        names said in the call, and who else was in it — takes a number or a name for \
        it, and rewrites the transcript with the names in. Each named voice is \
        kept as a voiceprint in \(VoiceLibrary.directory.path), on this machine only, \
        so the next call that voice is on comes back already named.

        Pass names as --name A=John, or run it in a terminal and answer the prompts. \
        An empty answer leaves the letter as it is.

        --people lists everyone remembered with their voiceprints, numbered, and the \
        recording each was named in; --remove-print John=2 removes one that was filed \
        under the wrong name.
        """
    )

    @Argument(help: "A recording folder. Defaults to the newest recording.")
    var path: String?

    @Option(name: .long, help: "A letter and a name, as A=John. Repeatable.")
    var name: [String] = []

    @Option(name: .long, help: "Mark a known person as you, the one recording, so your voice heard on the far end goes back to Me.")
    var me: String?

    @Flag(name: .long, help: "List everyone remembered, with their voiceprints numbered and where each came from.")
    var people = false

    @Option(name: .long, help: "A person and a voiceprint number from --people, as John=2: removes that print. Repeatable.")
    var removePrint: [String] = []

    @Option(name: .shortAndLong, help: "Where recordings live, when no path is given.")
    var output = Defaults.outputRoot

    @Flag(
        name: .long,
        help:
            "Fetch the speaker models (\(SpeakerSetup.downloadSize)) that tell voices apart, then stop."
    )
    var download = false

    func run() async throws {
        if download { return try await fetchModels() }
        if !removePrint.isEmpty {
            var library = VoiceLibrary.load()
            /// Highest number first, so removing one does not renumber the next.
            let pairs = try PeopleListing.parse(removePrint, in: library)
            let unique = pairs.enumerated().filter { index, pair in !pairs[..<index].contains { $0 == pair } }.map(\.element)
            for (person, number) in unique.sorted(by: { $0.1 > $1.1 }) {
                library.removePrint(at: number - 1, from: person)
                print("Removed voiceprint \(number) from \(person).")
            }
            try library.save()
        }
        if people || !removePrint.isEmpty {
            print(PeopleListing.text(VoiceLibrary.load()))
            if name.isEmpty, path == nil, me == nil { return }
        }
        if let me {
            var library = VoiceLibrary.load()
            guard library.names.contains(me) else {
                throw ValidationError("Nobody called \(me) is known yet. Name your voice in a transcript first.")
            }
            library.setOwner(me)
            try library.save()
            print("\(me) is marked as you.")
            if name.isEmpty, path == nil { return }
        }
        let folder = try resolveFolder()
        guard let voices = RecordingVoices.read(in: folder) else {
            throw VoiceNaming.Failure.nothingToName(folder: folder.lastPathComponent)
        }

        let given = try parse(name)
        let speakers = RecordingSpeakers.read(in: folder)
        let asking = speakers.map(SpeakerPrompt.questions) ?? []
        if !given.isEmpty {
            SpeakerPrompt.apply(given, in: folder)
        } else if Terminal.isInteractive, let speakers, !asking.isEmpty {
            let answers = SpeakerPrompt.ask(asking, in: speakers)
            if !answers.isEmpty { SpeakerPrompt.name(answers, in: folder) }
        } else {
            print(SpeakerPrompt.listing(in: folder))
            if let speakers {
                for row in asking { print("\n" + SpeakerPrompt.describe(row, in: speakers)) }
            }
            if !voices.unnamed.isEmpty { print("\nPass --name A=John to name one.") }
        }
    }

    /// The non-interactive way to what ⏎ on the setup screen's Speakers row does.
    private func fetchModels() async throws {
        guard !Readiness.speakersReady else {
            print("The speaker models are already in \(SpeakerSetup.directory.path).")
            return
        }
        print(
            "Downloading the speaker models (\(SpeakerSetup.downloadSize)) into "
                + "\(SpeakerSetup.directory.path)…")
        try await SpeakerSetup.fetch { print("  \($0)") }
        print("Done. Voices are told apart on this machine from now on.")
    }

    private func parse(_ pairs: [String]) throws -> [String: String] {
        var names: [String: String] = [:]
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw ValidationError("--name takes LETTER=NAME, as in --name A=John.")
            }
            names[parts[0].uppercased()] = parts[1]
        }
        return names
    }

    private func resolveFolder() throws -> URL {
        if let path {
            let url = URL(filePath: path.expandingTilde)
            guard Recordings.isDirectory(url) else {
                throw ValidationError("\(path) is not a recording folder.")
            }
            return url
        }
        guard let latest = Recordings.newest(in: URL(filePath: output.expandingTilde)) else {
            throw ValidationError("No recordings in \(output). Pass a folder instead.")
        }
        return latest
    }
}

/// `anyrec speakers --people`: everyone remembered, each print numbered with the recording
/// it was named in, as `--remove-print` refers to them.
enum PeopleListing {
    static func text(_ library: VoiceLibrary) -> String {
        guard !library.isEmpty else { return "Nobody is remembered yet. Name a voice in a transcript first." }
        return library.people.map { person in
            let header = "\(person.name)\(person.isOwner ? " (you)" : "") — "
                + (person.prints.count == 1 ? "1 voiceprint" : "\(person.prints.count) voiceprints")
            let prints = person.prints.indices.map { "  \($0 + 1)) \(origin(person.origin(ofPrint: $0)))" }
            return ([header] + prints).joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    /// Where one print came from: the recording folder and when it started, an import, or
    /// earlier for prints filed before that was kept.
    static func origin(_ origin: VoiceLibrary.PrintOrigin?) -> String {
        guard let origin else { return "earlier" }
        guard let recording = origin.recording else {
            return "imported \(origin.filed.formatted(date: .abbreviated, time: .omitted))"
        }
        guard let started = origin.recordingStarted else { return recording }
        return "\(recording) (\(started.formatted(date: .abbreviated, time: .shortened)))"
    }

    /// `John=2` pairs, checked against the library: the person must be known and have that print.
    static func parse(_ pairs: [String], in library: VoiceLibrary) throws -> [(String, Int)] {
        try pairs.map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let number = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                throw ValidationError("--remove-print takes NAME=NUMBER, as in --remove-print John=2.")
            }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard let person = library.people.first(where: { $0.name == name }) ?? library.person(answering: name) else {
                throw ValidationError("Nobody called \(name) is remembered. --people lists who is.")
            }
            guard person.prints.indices.contains(number - 1) else {
                throw ValidationError("\(person.name) has no voiceprint \(number). --people lists them.")
            }
            return (person.name, number)
        }
    }
}
