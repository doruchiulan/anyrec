import Foundation
import Testing

@testable import AnyRecKit

@Suite("Recording layout")
struct RecordingLayoutTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-layout-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ s: Int = 0) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    @Test("every kind of file has one place, and a name's flat spelling is only a fallback")
    func places() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = RecordingLayout(directory: root)
        let expected: [(String, String)] = [
            ("microphone.m4a", "Tracks/microphone.m4a"), ("system-audio.m4a", "Tracks/system-audio.m4a"),
            ("screen.mov", "Tracks/screen.mov"), ("microphone-clean.m4a", "Tracks/microphone-clean.m4a"),
            ("recording.json", "Data/recording.json"), ("call-participants.json", "Data/call-participants.json"),
            ("microphone-live.json", "Data/microphone-live.json"), ("transcription.json", "Data/transcription.json"),
            (".transcription.json", "Data/transcription.json"),
            ("transcript-parakeet-1.json", "Data/Transcripts/transcript-parakeet-1.json"),
            ("speakers-1.json", "Data/Transcripts/speakers-1.json"), ("wording-1.json", "Data/Transcripts/wording-1.json"),
            ("summary-parakeet-1.json", "Data/Transcripts/summary-parakeet-1.json"),
            ("transcript-apple.md", "Data/Transcripts/transcript-apple.md"), ("voices.json", "Data/Transcripts/voices.json"),
            ("review-1.json", "Data/Transcripts/review-1.json"),
            ("mix.json", "Cache/mix.json"), ("diarization.json", "Cache/diarization.json"),
            ("waveform.json", "Cache/waveform.json"), ("thumbnail.jpg", "Cache/thumbnail.jpg"), ("mix.wav", "Cache/mix.wav"),
            ("Transcript.md", "Transcript.md"), ("Summary.md", "Summary.md"), ("call.mp4", "call.mp4"),
            ("Design review – Slack – 2026-11-03 10.08.mp4", "Design review – Slack – 2026-11-03 10.08.mp4"),
            (".merge-1.mp4", ".merge-1.mp4"), (".compress-1.mp4", ".compress-1.mp4"),
        ]
        for (name, path) in expected {
            #expect(layout.url(name).path == layout.directory.path + "/" + path, "\(name)")
        }

        // Nothing on disk: the new place. A flat file only counts once it is there.
        #expect(layout.readURL("mix.json") == layout.url("mix.json"))
        try Data("x".utf8).write(to: root.appendingPathComponent("mix.json"))
        #expect(layout.readURL("mix.json").lastPathComponent == "mix.json")
        #expect(layout.readURL("mix.json").deletingLastPathComponent().lastPathComponent != "Cache")
        // Written, the new place wins, and writing makes its folder.
        try Data("y".utf8).write(to: layout.writeURL("mix.json"))
        #expect(layout.readURL("mix.json") == layout.url("mix.json"))
        #expect(try String(contentsOf: layout.readURL("mix.json"), encoding: .utf8) == "y")
    }

    @Test("a file's recording folder is found from any subfolder")
    func containing() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = RecordingLayout(directory: root)
        for name in ["microphone.m4a", "recording.json", "transcript-a-1.json", "mix.json", "call.mp4"] {
            #expect(RecordingLayout.containing(layout.url(name)).directory == layout.directory, "\(name)")
        }
    }

    @Test("an OutputPlan finds a flat folder's tracks where they are, and a fresh one's in Tracks and Data")
    func plans() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let flat = root.appendingPathComponent("rec-2026-11-18-152904")
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        for name in ["microphone.m4a", "system-audio.m4a", "microphone-live.json"] {
            try Data("x".utf8).write(to: flat.appendingPathComponent(name))
        }
        let old = OutputPlan(directory: flat)
        #expect(old.microphone.deletingLastPathComponent() == old.directory)
        #expect(old.microphoneLive.deletingLastPathComponent() == old.directory)

        let created = try OutputPlan.create(in: root, at: date(2026, 11, 18, 15, 29), title: "Weekly sync", app: "Slack")
        #expect(created.directory.lastPathComponent == "2026-11-18 15.29 Weekly sync – Slack")
        #expect(created.microphone.path.hasSuffix("/Tracks/microphone.m4a"))
        #expect(created.microphoneLive.path.hasSuffix("/Data/microphone-live.json"))
        #expect(FileManager.default.fileExists(atPath: created.directory.appendingPathComponent("Tracks").path))
        #expect(FileManager.default.fileExists(atPath: created.directory.appendingPathComponent("Data").path))
    }

    @Test("a readable folder name reuses the merged file's cleaning, and is unique in its root")
    func names() throws {
        let started = date(2026, 11, 18, 15, 29)
        #expect(RecordingMedia.folderName(title: "(3) QA & Doru - Blueprint - 2 new items - Slack", app: "Slack", started: started)
            == "2026-11-18 15.29 QA & Doru - Blueprint – Slack")
        #expect(RecordingMedia.folderName(title: "a/b: c|d?", app: nil, started: started) == "2026-11-18 15.29 a-b- c-d")
        #expect(RecordingMedia.folderName(title: "display 1", app: nil, started: started) == "2026-11-18 15.29 Display")
        #expect(RecordingMedia.folderName(title: String(repeating: "é", count: 200), app: "Slack", started: started).utf8.count < 200)

        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try OutputPlan.create(in: root, at: started, title: "Sync", app: "Slack")
        let second = try OutputPlan.create(in: root, at: started, title: "Sync", app: "Slack")
        let third = try OutputPlan.create(in: root, at: started, title: "Sync", app: "Slack")
        #expect([first, second, third].map { $0.directory.lastPathComponent } == [
            "2026-11-18 15.29 Sync – Slack", "2026-11-18 15.29 Sync – Slack (2)", "2026-11-18 15.29 Sync – Slack (3)"])
    }

    @Test("a recording is dated from recording.json, then a rec- name, then a readable name")
    func dates() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let exact = date(2026, 11, 18, 15, 29, 4)

        let readable = root.appendingPathComponent("2026-11-18 15.29 Sync – Slack")
        try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
        #expect(RecordingLibrary.knownStart(readable) == date(2026, 11, 18, 15, 29))
        #expect(CallSheet.date(of: readable) == "2026-11-18")

        let legacy = root.appendingPathComponent("rec-2026-11-18-152904")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        #expect(RecordingLibrary.knownStart(legacy) == exact)
        #expect(CallSheet.date(of: legacy) == "2026-11-18")

        // recording.json wins over whatever the name says.
        try RecordingInfo(title: "Sync", bundleID: nil, width: 1, height: 1, fps: 1,
                          id: "rec-2026-11-19-090000", startedAt: date(2026, 11, 19, 9, 0)).write(to: legacy)
        #expect(RecordingLibrary.knownStart(legacy) == date(2026, 11, 19, 9, 0))
        #expect(CallSheet.date(of: legacy) == "2026-11-19")
        #expect(RecordingInfo.read(legacy)?.id == "rec-2026-11-19-090000")
        let merged = RecordingMedia.mergedName(in: legacy, info: RecordingInfo.read(legacy), audioOnly: false)
        #expect(merged == "Sync – 2026-11-19 09.00.mp4")

        // An older recording.json without the new fields still reads.
        let old = root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data(#"{"title":"T","width":1,"height":1,"fps":1}"#.utf8).write(to: RecordingLayout(directory: old).writeURL("recording.json"))
        #expect(RecordingInfo.read(old)?.startedAt == nil && RecordingInfo.read(old)?.id == nil)
    }

    @Test("Transcript.md and Summary.md are the only renderings, rewritten with the selection; SRT is on demand")
    func renderings() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("call")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let voices = RecordingVoices(voices: [.init(letter: "A", print: [], sample: "", start: 0, end: 1)])
        let first = Transcript(utterances: [Utterance(start: 0, end: 1, text: "First", speaker: .voice("A"))], language: "en", engine: "parakeet")
        let files = try TranscriptStore.publish(first, voices: voices, in: folder)
        let top = try FileManager.default.contentsOfDirectory(atPath: RecordingLayout(directory: folder).directory.path).sorted()
        #expect(top == ["Data", "Transcript.md"])
        #expect(files.map(\.lastPathComponent).first == "Transcript.md")
        #expect(try String(contentsOf: folder.appendingPathComponent("Transcript.md"), encoding: .utf8).contains("First"))

        try TranscriptStore.publish(Transcript(utterances: [Utterance(start: 0, end: 1, text: "Second", speaker: .voice("A"))],
                                               language: "en", engine: "whisper"), voices: voices, in: folder)
        #expect(try String(contentsOf: folder.appendingPathComponent("Transcript.md"), encoding: .utf8).contains("Second"))

        let source = try #require(TranscriptStore.activeTranscript(in: folder))
        try TranscriptStore.publishSummary(Summary(overview: "Hello.", decisions: [], actions: [], provider: "t"), for: source, names: [:])
        #expect(try String(contentsOf: folder.appendingPathComponent("Summary.md"), encoding: .utf8).contains("Hello."))
        let transcripts = RecordingLayout(directory: folder).files(in: .transcripts).map(\.pathExtension)
        #expect(!transcripts.contains("md") && !transcripts.contains("srt"))
        #expect(try #require(TranscriptStore.srt(in: folder)).contains("Second"))
    }
}
