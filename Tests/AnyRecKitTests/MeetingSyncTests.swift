import AVFoundation
import Foundation
import Testing
@testable import AnyRecKit

@Suite("Team meeting sync")
struct MeetingSyncTests {
    struct Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source: URL
        let folder: URL
        let other: URL
        let library: URL
        let owner: MeetingSync
        let reader: MeetingSync
        let media = Data("merged media".utf8)
        init() throws {
            source = root.appending(path: "OwnerLibrary/Call", directoryHint: .isDirectory)
            folder = root.appending(path: "Engineering", directoryHint: .isDirectory)
            other = root.appending(path: "Client", directoryHint: .isDirectory)
            library = root.appending(path: "ReaderLibrary", directoryHint: .isDirectory)
            owner = MeetingSync(stateFile: root.appending(path: "owner.json"))
            reader = MeetingSync(stateFile: root.appending(path: "reader.json"))
            for dir in [folder, other, source] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            try media.write(to: source.appending(path: "call.mp4"))
            try RecordingInfo(title: "Weekly meeting", bundleID: nil, width: 12, height: 12, fps: 24).write(to: source)
            try Data("raw microphone".utf8).write(to: RecordingLayout(directory: source).writeURL("microphone.m4a"))
            try revise("Friday")
        }
        func revise(_ text: String) throws {
            let t = Transcript(utterances: [.init(start: 1, end: 2, text: text, speaker: .me)], language: "en", engine: "parakeet",
                               notes: ["Private diagnostic"])
            try TranscriptStore.publish(t, voices: nil, in: source)
            let url = try #require(TranscriptStore.activeTranscript(in: source))
            try TranscriptStore.publishSummary(Summary(overview: text, decisions: [], actions: [], provider: "Test"), for: url, names: [:])
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func explicitSyncAndUpdates() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try await f.reader.connect(f.folder)
        #expect(try await f.reader.refresh().meetings.isEmpty)
        try await f.owner.sync(f.source, to: f.folder)
        let first = try #require(try await f.reader.refresh().meetings.first)
        #expect(first.meeting.transcript?.utterances.first?.speaker == .named("Recorder"))
        #expect(first.meeting.transcript?.notes.isEmpty == true)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: first.directory.path)) ==
            ["Meeting.json", "Transcript.md", "Recording.mp4", "Summary.md"])
        try await f.reader.addToLibrary(first.directory)
        try f.revise("Monday")
        let restarted = MeetingSync(stateFile: f.root.appending(path: "owner.json"))
        #expect(try await restarted.refresh().failures.isEmpty)
        let view = try await f.reader.refresh()
        let updated = try #require(view.meetings.first)
        #expect(updated.id == first.id && view.state.linked.contains(first.id))
        #expect(updated.meeting.summary?.overview == "Monday")
        #expect(updated.meeting.transcript?.utterances.first?.text == "Monday")
        #expect(try Data(contentsOf: updated.directory.appending(path: "Recording.mp4")) == f.media)
    }

    @Test("a changed or deleted shared file is put back from the owner's recording, and nothing is rewritten when the copy is intact")
    func repairsTheSharedCopy() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try await f.owner.sync(f.source, to: f.folder)
        var view = try await f.owner.refresh()
        let publication = try #require(view.state.publications.values.first)
        let summary = publication.directory.appending(path: "Summary.md")
        let original = try Data(contentsOf: summary)
        #expect(publication.restored == nil)

        /// Intact: refreshing writes nothing.
        let written = try summary.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        view = try await f.owner.refresh()
        #expect(try summary.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == written)
        #expect(view.state.publications.values.first?.restored == nil)

        /// Someone with edit access rewrites the summary: it is put back, and that is noted.
        try Data("Somebody else's summary".utf8).write(to: summary)
        view = try await f.owner.refresh()
        #expect(try Data(contentsOf: summary) == original)
        #expect(view.state.publications.values.first?.restored != nil)

        /// The recording is deleted: it is copied back.
        let media = publication.directory.appending(path: "Recording.mp4")
        try FileManager.default.removeItem(at: media)
        _ = try await f.owner.refresh()
        #expect(try Data(contentsOf: media) == f.media)

        /// The owner's own recording was never touched.
        #expect(try Data(contentsOf: f.source.appending(path: "call.mp4")) == f.media)
    }

    @Test("a folder is named by the cloud that keeps it")
    func cloudProvider() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(CloudFolder.provider(of: home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/AnyRec"), home: home) == "iCloud Drive")
        #expect(CloudFolder.provider(of: home.appending(path: "Library/CloudStorage/OneDrive-Blueprint/AnyRec Team"), home: home) == "OneDrive – Blueprint")
        #expect(CloudFolder.provider(of: home.appending(path: "Library/CloudStorage/OneDrive-Personal/x"), home: home) == "OneDrive")
        #expect(CloudFolder.provider(of: home.appending(path: "Library/CloudStorage/GoogleDrive-me@x.com/My Drive"), home: home) == "Google Drive")
        #expect(CloudFolder.provider(of: home.appending(path: "Library/CloudStorage/Dropbox/Team"), home: home) == "Dropbox")
        #expect(CloudFolder.provider(of: home.appending(path: "Documents/Team"), home: home) == nil)
    }

    @Test func copyMoveAndRemove() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try await f.owner.sync(f.source, to: f.folder)
        try await f.reader.connect(f.folder)
        let item = try #require(try await f.reader.refresh().meetings.first)
        try await f.reader.addToLibrary(item.directory)
        let copy = try item.meeting.makeCopy(from: item.directory, in: f.library)
        let original = try #require(RecordingTranscript.read(in: copy)?.named)
        var lines = original.utterances
        lines[0].text = "Only in my copy"
        lines[0].speaker = .named("Alice")
        try SharedCopy.edit(in: copy, original: original, lines: lines)
        #expect(RecordingTranscript.read(in: copy)?.named.utterances == lines)
        #expect(TranscriptStore.activeSummary(in: copy).flatMap(Summary.read)?.overview == "Friday")
        let fresh = try await SummaryPass.write(in: copy, request: .init(provider: .claude)) { _, input, _ in
            #expect(input.contains("Only in my copy"))
            return #"{"overview":"Revised summary"}"#
        }
        #expect(Summary.read(fresh)?.overview == "Revised summary")
        #expect(TranscriptionService.tracks(in: OutputPlan(directory: copy)).isEmpty)
        #expect(try await f.reader.refresh().meetings.first?.meeting.transcript?.utterances.first?.text == "Friday")
        try await f.owner.sync(f.source, to: f.other)
        let afterMove = try await f.reader.refresh()
        #expect(afterMove.meetings.isEmpty && afterMove.state.linked.isEmpty)
        try await f.reader.connect(f.other)
        let moved = try #require(try await f.reader.refresh().meetings.first)
        #expect(moved.meeting.id == item.meeting.id && moved.directory != item.directory)
        try await f.reader.addToLibrary(moved.directory)
        try await f.owner.remove(f.source)
        let removed = try await f.reader.refresh()
        #expect(removed.meetings.isEmpty && removed.state.linked.isEmpty)
        #expect(RecordingTranscript.read(in: copy)?.named.utterances == lines)
        #expect(try Data(contentsOf: f.source.appending(path: "call.mp4")) == f.media)
    }

    @Test func offlineFolderAndSafeRemoval() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try await f.owner.sync(f.source, to: f.folder)
        try await f.reader.connect(f.folder)
        let item = try #require(try await f.reader.refresh().meetings.first)
        try await f.reader.addToLibrary(item.directory)
        let parked = f.root.appending(path: "unmounted")
        try FileManager.default.moveItem(at: f.folder, to: parked)
        #expect(try await f.reader.refresh().state.linked.contains(item.directory))
        try FileManager.default.moveItem(at: parked, to: f.folder)
        let extra = item.directory.appending(path: "Budget.xlsx")
        try Data([1]).write(to: extra)
        await #expect(throws: (any Error).self) { try await f.owner.remove(f.source) }
        #expect(try Data(contentsOf: extra) == Data([1]))
        try FileManager.default.removeItem(at: extra)
        #expect(try await f.owner.refresh().state.publications.isEmpty)
    }
    @Test func storageMoveAndPrivateReplacement() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try await f.owner.sync(f.source, to: f.folder)
        let moved = f.library.appending(path: "Call", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: f.library, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: f.source, to: moved)
        try await f.owner.relocate(to: [moved])
        try await f.reader.connect(f.folder)
        #expect(try await f.owner.refresh().state.publications.count == 1)
        let remote = try #require(try await f.reader.refresh().meetings.first)
        try FileManager.default.removeItem(at: RecordingLayout(directory: moved).url("sync-id"))
        try Data("Private replacement".utf8).write(to: moved.appending(path: "call.mp4"))
        #expect(try await f.owner.refresh().failures.count == 1)
        #expect(try Data(contentsOf: remote.directory.appending(path: remote.meeting.mediaName)) == f.media)
    }

    @Test(.enabled(if: Muxer.ffmpegPath() != nil))
    func audioOnlyPlayback() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let media = f.source.appending(path: "Meeting.m4a")
        let ffmpeg = try #require(Muxer.ffmpegPath())
        let result = try Shell.run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:a", "aac", media.path])
        try #require(result.succeeded)
        try RecordingInfo(title: "Audio", bundleID: nil, width: 0, height: 0, fps: 0,
                          audioOnly: true, mergedFile: media.lastPathComponent).write(to: f.source)
        try await f.owner.sync(f.source, to: f.folder)
        try await f.reader.connect(f.folder)
        let item = try #require(try await f.reader.refresh().meetings.first)
        let remote = try await item.meeting.playableFile(in: item.directory)
        let copy = try item.meeting.makeCopy(from: item.directory, in: f.library)
        let local = try #require(RecordingLibrary.entry(at: copy).media)
        for file in [remote, local] {
            let asset = AVURLAsset(url: file)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            #expect(tracks.count == 1)
            #expect(try await asset.load(.duration).seconds >= 1.9)
        }
    }

}
