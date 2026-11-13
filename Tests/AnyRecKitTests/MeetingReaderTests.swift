import Foundation
import Testing
@testable import AnyRecKit

@Suite("Read-only meeting library")
struct MeetingReaderTests {
    @Test("Reads selected transcript, names, summary and participant evidence without exposing voiceprints")
    func selected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = try MeetingReader(root: fixture.root)
        let meeting = try reader.meeting(fixture.id)
        #expect(meeting.title == "Planning call")
        #expect(meeting.transcriptAvailable && meeting.summaryAvailable)
        let transcript = try reader.transcript(fixture.id)
        #expect(transcript.lines.map(\.text) == ["Ședință about shipping.", "Deploy on Friday."])
        #expect(transcript.lines.first?.speaker == "Speaker A")
        #expect(transcript.lines.first?.speakerName == "Alex")
        #expect(transcript.lines.last?.start == 10)
        let participants = try reader.participants(fixture.id)
        #expect(participants.observedInCall == ["Alex", "Silent guest"])
        #expect(participants.transcriptSpeakers.map(\.name) == ["Alex"])
        let encoded = String(decoding: try JSONEncoder().encode(participants), as: UTF8.self)
        #expect(!encoded.contains("\"print\"") && !encoded.contains("\"sample\""))
        let summary = try reader.summary(fixture.id).summary
        #expect(summary?.actions.first?.at == 10 && summary?.actions.first?.done == true)
        #expect(summary?.decisions == ["Ship Friday"])
    }

    @Test("Search finds current text and summary actions with timestamped excerpts and literal matching")
    func search() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = try MeetingReader(root: fixture.root)
        #expect(try reader.search("sedinta", scope: "transcript").items.first?.start == 0)
        #expect(try reader.search("OBSOLETE").items.isEmpty)
        #expect(try reader.search("ship.*").items.isEmpty)
        #expect(try reader.search("Silent", scope: "participants").items.first?.field == "participants")
        #expect(try reader.search("release checklist", scope: "summary").items.count == 1)
        let first = try reader.search("Friday", limit: 1)
        #expect(first.items.count == 1 && first.nextOffset == 1)
        let second = try reader.search("Friday", offset: 1, limit: 1)
        #expect(second.items.first?.field == "transcript" && second.nextOffset == nil)
    }

    @Test("Listing and transcript pagination respect filters and return stable line indices")
    func pages() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = try MeetingReader(root: fixture.root)
        #expect(try reader.list(filter: .init(query: "planning", participant: "SILENT")).items.count == 1)
        #expect(try reader.list(filter: .init(participant: "Unknown")).items.isEmpty)
        let date = try reader.meeting(fixture.id).startedAt
        #expect(try reader.list(filter: .init(after: date)).items.count == 1)
        #expect(try reader.list(filter: .init(before: date)).items.isEmpty)
        let first = try reader.transcript(fixture.id, limit: 1)
        #expect(first.nextOffset == 1 && first.lines.first?.index == 0)
        let second = try reader.transcript(fixture.id, offset: 1, limit: 1)
        #expect(second.nextOffset == nil && second.lines.first?.index == 1)
        #expect(try reader.transcript(fixture.id, start: 7, end: 12).lines.map(\.index) == [1])
        #expect(try reader.transcript(fixture.id, offset: Int.max).lines.isEmpty)
        #expect(throws: (any Error).self) { try reader.transcript(fixture.id, start: 12, end: 7) }
        #expect(throws: (any Error).self) { try reader.list(limit: 101) }
    }

    @Test("Regeneration immediately selects the new generation and does not resurrect an old summary")
    func regeneration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = try MeetingReader(root: fixture.root)
        let old = try reader.transcript(fixture.id)
        let revised = Transcript(utterances: [.init(start: 3, end: 5, text: "Monday instead", speaker: .me)],
                                 language: "en", engine: "whisper")
        try TranscriptStore.publish(revised, voices: nil, in: fixture.directory)
        let new = try reader.transcript(fixture.id)
        #expect(new.generation != old.generation)
        #expect(new.lines.first?.text == "Monday instead")
        #expect(try reader.summary(fixture.id).summary == nil)
        #expect(try reader.search("Friday").items.isEmpty)
        #expect(try reader.participants(fixture.id).transcriptSpeakers.first?.label == "Me")
    }

    @Test("All queries preserve every library file byte for byte")
    func noWrites() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.contents()
        let reader = try MeetingReader(root: fixture.root)
        _ = try reader.list()
        _ = try reader.search("Friday")
        _ = try reader.meeting(fixture.id)
        _ = try reader.transcript(fixture.id)
        _ = try reader.summary(fixture.id)
        _ = try reader.participants(fixture.id)
        #expect(try fixture.contents() == before)
    }

    @Test("Traversal, symlinked meetings and symlinked artifacts cannot escape the configured library")
    func confinement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = try MeetingReader(root: fixture.root)
        for id in ["../outside", "/tmp/rec-private", "rec-../..", "recording.json", "rec-missing"] {
            #expect(throws: (any Error).self) { try reader.meeting(id) }
        }
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("rec-escape"), withDestinationURL: outside)
        #expect(try reader.list().items.count == 1)
        #expect(throws: (any Error).self) { try reader.meeting("rec-escape") }
        let file = try #require(TranscriptStore.activeTranscript(in: fixture.directory))
        let secret = outside.appendingPathComponent("secret.json")
        try FileManager.default.moveItem(at: file, to: secret)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
        #expect(throws: (any Error).self) { try reader.transcript(fixture.id) }
        #expect(try reader.meeting(fixture.id).warnings.contains("Blocked a file outside this meeting."))
    }

    @Test("Corrupt selection is reported and never falls back to stale artifacts")
    func corruptSelection() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("bad JSON".utf8).write(to: fixture.directory.appendingPathComponent(".transcription.json"))
        let reader = try MeetingReader(root: fixture.root)
        let entry = try #require(reader.list().items.first)
        #expect(!entry.transcriptAvailable && !entry.warnings.isEmpty)
        #expect(try reader.summary(fixture.id).summary == nil)
        let search = try reader.search("OBSOLETE")
        #expect(search.items.isEmpty && !search.warnings.isEmpty)
    }

    @Test("Legacy recordings without a selection can return a Markdown summary and unnamed voices")
    func legacy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let selected = fixture.directory.appendingPathComponent(".transcription.json")
        try FileManager.default.removeItem(at: selected)
        try "Old summary".write(to: fixture.directory.appendingPathComponent("summary-apple.md"), atomically: true, encoding: .utf8)
        let reader = try MeetingReader(root: fixture.root)
        #expect(try reader.transcript(fixture.id).engine == "apple")
        #expect(try reader.summary(fixture.id).markdown == "Old summary")
        #expect(try reader.participants(fixture.id).transcriptSpeakers.first?.name == nil)
    }

    private struct Fixture {
        let root: URL
        let id = "rec-2026-11-01-120000"
        var directory: URL { root.appendingPathComponent(id) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-mcp-\(UUID())").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try RecordingInfo(title: "Planning call", bundleID: "com.tinyspeck.slackmacgap", width: 100, height: 100, fps: 30).write(to: directory)
            let old = Transcript(utterances: [.init(start: 0, end: 5, text: "OBSOLETE")], language: "en", engine: "apple")
            try JSONEncoder().encode(old).write(to: directory.appendingPathComponent("transcript-apple.json"))
            let current = Transcript(utterances: [
                .init(start: 0, end: 5, text: "Ședință about shipping.", speaker: .voice("A")),
                .init(start: 10, end: 15, text: "Deploy on Friday.", speaker: .voice("A")),
            ], language: "en", engine: "reviewed")
            let voices = RecordingVoices(voices: [.init(letter: "A", print: [1, 0], sample: "Voice sample", start: 0, end: 5, name: "Alex")])
            let files = try TranscriptStore.publish(current, voices: voices, in: directory)
            let summary = TranscriptStore.summaryDestination(for: files[2])
            try Summary(overview: "Release planning", decisions: ["Ship Friday"],
                actions: [.init(task: "Prepare release checklist", owner: "Alex", at: 10, done: true)], provider: "test").write(to: summary)
            try TranscriptStore.selectSummary(summary, for: files[2])
            try CallParticipants(observations: [.init(at: 1, source: "slack", participants: ["Alex", "Silent guest"], speaking: ["Alex"])]).write(in: directory)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func contents() throws -> [String: Data] {
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return try Dictionary(uniqueKeysWithValues: urls.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        }
    }
}
