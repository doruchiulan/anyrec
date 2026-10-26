import ArgumentParser
import Foundation
import AnyRecKit

struct Speakers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speakers",
        abstract: "Put names to the voices in a transcript, and remember them for next time.",
        discussion: """
        A transcript whose far end was told apart labels it Speaker A, Speaker B and \
        so on. This lists each letter with the longest thing it said, takes a name \
        for it, and rewrites the transcript with the names in. Each named voice is \
        kept as a voiceprint in \(VoiceLibrary.directory.path), on this machine only, \
        so the next call that voice is on comes back already named.

        Pass names as --name A=John, or run it in a terminal and answer the prompts. \
        An empty answer leaves the letter as it is.
        """
    )

    @Argument(help: "A recording folder. Defaults to the newest recording.")
    var path: String?

    @Option(name: .long, help: "A letter and a name, as A=John. Repeatable.")
    var name: [String] = []

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
        let folder = try resolveFolder()
        guard let voices = RecordingVoices.read(in: folder) else {
            throw VoiceNaming.Failure.nothingToName(folder: folder.lastPathComponent)
        }

        let given = try parse(name)
        if !given.isEmpty {
            SpeakerPrompt.apply(given, in: folder)
        } else if Terminal.isInteractive, !voices.unnamed.isEmpty {
            SpeakerPrompt.offer(voices, in: folder)
        } else {
            print(SpeakerPrompt.listing(voices))
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
