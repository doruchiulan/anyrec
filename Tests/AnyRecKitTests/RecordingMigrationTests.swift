import Foundation
import Testing

@testable import AnyRecKit

@Suite("Recording migration")
struct RecordingMigrationTests {
    private let fm = FileManager.default

    private func scratch() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("anyrec-migrate-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Every file under `folder`, relative, directories included.
    private func tree(_ folder: URL) -> [String] {
        ((try? fm.subpathsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// A folder as 0.8.x left it: everything flat, a layered selection in `.transcription.json`,
    /// UUID generations with their per-generation Markdown and SRT, and older kinds of file.
    private func legacyFolder(in root: URL, name: String = "rec-2026-11-18-152904") throws -> (URL, [String: Date]) {
        let folder = root.appendingPathComponent(name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Build the layered files with the writer itself, then lay them out flat.
        let voices = RecordingVoices(voices: [.init(letter: "A", print: [], sample: "Hello", start: 0, end: 1, name: "Maria")])
        let transcript = Transcript(utterances: [Utterance(start: 0, end: 1, text: "Hello", speaker: .voice("A"))],
                                    language: "en", engine: "parakeet")
        let files = try TranscriptStore.publish(transcript, voices: voices, in: folder)
        try TranscriptStore.publishSummary(Summary(overview: "Said hello.", decisions: [], actions: [], provider: "t"),
                                           for: files[1], names: [:])
        let layout = RecordingLayout(directory: folder)
        for url in layout.files(in: .transcripts) {
            try fm.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
        try fm.moveItem(at: layout.url("transcription.json"), to: folder.appendingPathComponent(".transcription.json"))
        try fm.removeItem(at: folder.appendingPathComponent("Transcript.md"))
        try? fm.removeItem(at: folder.appendingPathComponent("Summary.md"))
        try fm.removeItem(at: folder.appendingPathComponent("Data"))
        let generation = UUID().uuidString
        for extra in [
            "recording.json", "call-participants.json", "microphone-live.json", "mix.json", "diarization.json",
            "waveform.json", "thumbnail.jpg", "mix.wav", "microphone.m4a", "system-audio.m4a", "screen.mov",
            "microphone-clean.m4a", "call.mp4", "voices.json", "voices-\(generation).json", "review-\(generation).json",
            "transcript-whisper.json", "transcript-whisper.md", "transcript-whisper.srt",
            "transcript-parakeet-\(generation).md", "transcript-parakeet-\(generation).srt", "summary-whisper.md", ".DS_Store",
        ] {
            try Data(extra.utf8).write(to: folder.appendingPathComponent(extra))
        }
        let info = RecordingInfo(title: "QA & Doru - Blueprint - Slack", bundleID: "com.tinyspeck.slackmacgap",
                                 width: 10, height: 10, fps: 30, mergedFile: "call.mp4")
        try JSONEncoder().encode(info).write(to: folder.appendingPathComponent("recording.json"))
        // A modification time `mix.json` could be keyed to.
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        var times: [String: Date] = [:]
        for name in ["microphone.m4a", "system-audio.m4a", "microphone-live.json"] {
            try fm.setAttributes([.modificationDate: when], ofItemAtPath: folder.appendingPathComponent(name).path)
            times[name] = when
        }
        return (folder, times)
    }

    @Test("a realistic flat folder becomes exactly the new tree, nothing lost, with a readable name")
    func migratesFolder() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let (folder, times) = try legacyFolder(in: root)
        let flat = tree(folder)
        let before = OutputPlan(directory: folder)
        let basis = MixDecision.Basis.of(before)
        let read = try #require(RecordingTranscript.read(in: folder))
        let beforeNames = read.voices?.names

        let migrated = RecordingMigration.migrate(folder: folder)

        #expect(migrated.lastPathComponent == "2026-11-18 15.29 QA & Doru - Blueprint – Slack")
        #expect(!fm.fileExists(atPath: folder.path))
        let transcripts = flat.filter { RecordingLayout.place(of: $0) == .transcripts }
        #expect(transcripts.count >= 10)
        var expected: [String] = ["Cache", "Data", "Data/Transcripts", "Tracks", "Transcript.md", "Summary.md", "call.mp4", ".DS_Store"]
        expected += ["mix.json", "diarization.json", "waveform.json", "thumbnail.jpg", "mix.wav"].map { "Cache/" + $0 }
        expected += ["recording.json", "call-participants.json", "microphone-live.json"].map { "Data/" + $0 }
        expected.append("Data/transcription.json")
        expected += transcripts.map { "Data/Transcripts/" + $0 }
        expected += ["microphone.m4a", "system-audio.m4a", "screen.mov", "microphone-clean.m4a"].map { "Tracks/" + $0 }
        #expect(tree(migrated) == expected.sorted())

        // Nothing was rewritten: contents and modification times are those of the flat files.
        let after = OutputPlan(directory: migrated)
        #expect(MixDecision.Basis.of(after) == basis, "mix.json stays keyed to the same tracks")
        for (name, when) in times {
            let url = RecordingLayout(directory: migrated).url(name)
            #expect(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == when)
        }
        #expect(try String(contentsOf: RecordingLayout(directory: migrated).url("mix.json"), encoding: .utf8) == "mix.json")

        // recording.json learned its identity; everything still reads.
        let info = try #require(RecordingInfo.read(migrated))
        #expect(info.id == "rec-2026-11-18-152904" && info.startedAt != nil && info.mergedFile == "call.mp4")
        #expect(RecordingTranscript.read(in: migrated)?.voices?.names == beforeNames)
        #expect(try String(contentsOf: migrated.appendingPathComponent("Transcript.md"), encoding: .utf8).contains("Maria"))
        #expect(try String(contentsOf: migrated.appendingPathComponent("Summary.md"), encoding: .utf8).contains("Said hello."))
        #expect(RecordingMedia.merged(in: migrated)?.lastPathComponent == "call.mp4")
        #expect(RecordingLibrary.entry(at: migrated).summary != nil)
        #expect(RecordingLayout(directory: migrated).identity == "rec-2026-11-18-152904")
    }

    @Test("running it again changes nothing")
    func idempotent() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        _ = try legacyFolder(in: root)
        let first = RecordingMigration.migrateAll(in: root)
        #expect(first.migrated.count == 1)
        let folder = try #require(first.migrated.first)
        let snapshot = tree(folder)
        let infoBytes = try Data(contentsOf: RecordingLayout(directory: folder).url("recording.json"))
        let times = try snapshot.map { try folder.appendingPathComponent($0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }

        let second = RecordingMigration.migrateAll(in: root)

        #expect(second.migrated.isEmpty && second.moved.isEmpty)
        #expect(tree(folder) == snapshot)
        #expect(try Data(contentsOf: RecordingLayout(directory: folder).url("recording.json")) == infoBytes)
        #expect(try snapshot.map { try folder.appendingPathComponent($0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } == times)
        #expect(try fm.contentsOfDirectory(atPath: root.path).count == 1)
    }

    @Test("an interrupted run is finished by the next, and a file already in place is never overwritten")
    func resumes() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let (folder, _) = try legacyFolder(in: root)
        let layout = RecordingLayout(directory: folder)
        // Half done: one file moved already, another has a different copy in the new place.
        try layout.prepare(RecordingLayout.Place.allCases.filter { $0 != .top })
        try fm.moveItem(at: folder.appendingPathComponent("waveform.json"), to: layout.url("waveform.json"))
        try Data("newer".utf8).write(to: layout.url("mix.json"))

        let migrated = RecordingMigration.migrate(folder: folder)

        let after = RecordingLayout(directory: migrated)
        #expect(try String(contentsOf: after.url("mix.json"), encoding: .utf8) == "newer")
        #expect(fm.fileExists(atPath: migrated.appendingPathComponent("mix.json").path), "the older copy is kept where it was")
        #expect(fm.fileExists(atPath: after.url("waveform.json").path))
        #expect(fm.fileExists(atPath: after.url("microphone.m4a").path))
    }

    @Test("two recordings with one readable name get (2), and a folder with no recording.json keeps its name")
    func collisions() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let a = try legacyFolder(in: root, name: "rec-2026-11-18-152904").0
        let b = try legacyFolder(in: root, name: "rec-2026-11-18-152931").0
        let bare = root.appendingPathComponent("rec-2026-11-17-090000")
        try fm.createDirectory(at: bare, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: bare.appendingPathComponent("microphone.m4a"))
        _ = (a, b)

        _ = RecordingMigration.migrateAll(in: root)

        let names = try fm.contentsOfDirectory(atPath: root.path).sorted()
        #expect(names == ["2026-11-18 15.29 QA & Doru - Blueprint – Slack",
                          "2026-11-18 15.29 QA & Doru - Blueprint – Slack (2)", "rec-2026-11-17-090000"])
        #expect(fm.fileExists(atPath: bare.appendingPathComponent("Tracks/microphone.m4a").path))
        #expect(RecordingLibrary.entries(in: root).map(\.name).count == 3)
    }

    @Test("a folder something is working on is left alone")
    func busy() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let (folder, _) = try legacyFolder(in: root)
        let flat = tree(folder)

        let report = RecordingMigration.migrateAll(in: root) { $0.standardizedFileURL == folder.standardizedFileURL }

        #expect(report.skipped.count == 1 && report.migrated.isEmpty)
        #expect(tree(folder) == flat)
    }

    @Test("moving the root moves every recording, keeps clashing names, and leaves a folder with only .DS_Store removed")
    func rootMove() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("Desktop/AnyRec Recordings")
        let new = root.appendingPathComponent("Library/Recordings")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: new.appendingPathComponent("rec-2026-11-18-152904"), withIntermediateDirectories: true)
        let (moved, _) = try legacyFolder(in: old, name: "rec-2026-11-18-152904")
        _ = try legacyFolder(in: old, name: "rec-2026-11-19-100000")
        try Data().write(to: old.appendingPathComponent(".DS_Store"))
        let flat = tree(moved)

        let report = RecordingMigration.run(root: new, legacyRoot: old, movesLegacyRoot: true)

        #expect(report.moved.count == 2 && report.failures.isEmpty)
        #expect(!fm.fileExists(atPath: old.path), "only .DS_Store was left, so the old folder goes")
        let names = try fm.contentsOfDirectory(atPath: new.path).sorted()
        #expect(names.count == 3, "the clashing name is kept as (2), the existing folder untouched: \(names)")
        #expect(names.contains { $0.contains("(2)") || $0.hasPrefix("rec-2026-11-18-152904") })
        #expect(RecordingLibrary.entries(in: new).count == 3)
        let migratedTrees = try names.map { tree(new.appendingPathComponent($0)) }
        #expect(migratedTrees.contains { $0.contains("Tracks/microphone.m4a") })
        #expect(flat.contains("microphone.m4a"))
    }

    @Test("the old root stays when it holds anything else, and a busy folder stays in it")
    func rootMoveKeeps() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        let (busy, _) = try legacyFolder(in: old, name: "rec-2026-11-18-152904")
        try Data("mine".utf8).write(to: old.appendingPathComponent("notes.txt"))

        let report = RecordingMigration.moveRoot(from: old, to: new) { $0.standardizedFileURL == busy.standardizedFileURL }

        #expect(report.skipped.count == 1 && report.moved.isEmpty)
        #expect(fm.fileExists(atPath: old.appendingPathComponent("notes.txt").path))
        #expect(fm.fileExists(atPath: busy.path))
    }

    @Test("a new root is refused when it is inside the current one, the same, around it, or not writable")
    func validation() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let current = root.appendingPathComponent("Recordings")
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        #expect(throws: RecordingMigration.MoveError.sameFolder) { try RecordingMigration.validateMove(from: current, to: current) }
        #expect(throws: RecordingMigration.MoveError.insideCurrent) {
            try RecordingMigration.validateMove(from: current, to: current.appendingPathComponent("more"))
        }
        #expect(throws: RecordingMigration.MoveError.containsCurrent) { try RecordingMigration.validateMove(from: current, to: root) }
        let readOnly = root.appendingPathComponent("locked")
        try fm.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path) }
        if getuid() != 0 {
            #expect(throws: RecordingMigration.MoveError.self) { try RecordingMigration.validateMove(from: current, to: readOnly) }
        }
        try RecordingMigration.validateMove(from: current, to: root.appendingPathComponent("elsewhere"))
        #expect(RecordingMigration.MoveError.insideCurrent.errorDescription?.isEmpty == false)
    }

    @Test("a voiceprint's origin names the old id, which the renamed recording still answers to")
    func printOrigins() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        _ = try legacyFolder(in: root)
        let migrated = try #require(RecordingMigration.migrateAll(in: root).migrated.first)
        let entry = RecordingLibrary.entry(at: migrated)
        #expect(entry.recordingID == "rec-2026-11-18-152904")
        let origin = VoiceLibrary.PrintOrigin(recording: "rec-2026-11-18-152904")
        #expect(origin.recordingStarted != nil)
        #expect(entry.name != origin.recording && entry.recordingID == origin.recording)
    }
}
