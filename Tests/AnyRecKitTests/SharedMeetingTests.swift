import AVFoundation
import Foundation
import Testing
@testable import AnyRecKit

@Suite("Shared meetings")
struct SharedMeetingTests {
    private typealias Fixture = MeetingSyncTests.Fixture

    private func tone(_ file: URL, seconds: Int) throws {
        let ffmpeg = try #require(Muxer.ffmpegPath())
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = try Shell.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
                                            "-c:a", "aac", file.path])
        try #require(result.succeeded)
    }

    private func withTracks(_ f: Fixture, live: MicrophoneLive?) throws {
        let plan = OutputPlan(directory: f.source)
        try FileManager.default.createDirectory(at: plan.systemAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try tone(plan.systemAudio, seconds: 6)
        try tone(plan.microphone, seconds: 6)
        try live?.write(to: plan.microphoneLive)
    }

    private func item(_ f: Fixture) async throws -> SharedLibraryItem {
        try await f.owner.sync(f.source, to: f.folder)
        try await f.reader.connect(f.folder)
        return try #require(try await f.reader.refresh().meetings.first)
    }

    @Test("the microphone is shared silent wherever the call was not listening, and the master is untouched",
          .enabled(if: Muxer.ffmpegPath() != nil))
    func microphoneSilencedWhereMuted() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try withTracks(f, live: MicrophoneLive(duration: 6, spans: [0..<2, 4..<6], muteRead: true))
        let master = try Data(contentsOf: OutputPlan(directory: f.source).microphone)
        let shared = try await item(f)
        let track = shared.directory.appending(path: SharedMeeting.microphoneTrack)
        let ffmpeg = try #require(Muxer.ffmpegPath())
        let envelope = try #require(AudioEnvelope.of([track], using: ffmpeg)[0])
        let loudest = { (from: Double, to: Double) in envelope.frames[Int(from * 50)..<Int(to * 50)].max() ?? 0 }
        #expect(loudest(0.5, 1.5) > 500 && loudest(4.5, 5.5) > 500)
        #expect(loudest(2.3, 3.7) < 5)
        #expect(try Data(contentsOf: OutputPlan(directory: f.source).microphone) == master)
        #expect(try Data(contentsOf: shared.directory.appending(path: SharedMeeting.callTrack))
            == Data(contentsOf: OutputPlan(directory: f.source).systemAudio))
        let entry = shared.meeting.entry(in: shared.directory)
        #expect(entry.shared?.tracks.count == 2 && entry.shared?.microphone == track)
    }

    @Test("a microphone whose mute was never followed stays with its owner", .enabled(if: Muxer.ffmpegPath() != nil))
    func unfollowedMuteIsNotShared() async throws {
        for live in [nil, MicrophoneLive(duration: 6, spans: [0..<6]), MicrophoneLive(duration: 6, spans: [0..<6], muteRead: false)] {
            let f = try Fixture()
            defer { f.clean() }
            try withTracks(f, live: live)
            let shared = try await item(f)
            #expect(!FileManager.default.fileExists(atPath: shared.directory.appending(path: SharedMeeting.microphoneTrack).path))
            #expect(shared.meeting.origin(in: shared.directory).microphone == nil)
            #expect(shared.meeting.origin(in: shared.directory).callAudio != nil)
        }
        #expect(MicrophoneLive(duration: 6, spans: [0..<2, 4..<6]).followedMute)
        #expect(MicrophoneLive(duration: 6, spans: [0..<6], muteRead: true).followedMute)
    }

    @Test("whether the mute was read survives the file, and older files read without it")
    func muteReadOnDisk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try MicrophoneLive(duration: 3, spans: [0..<3], muteRead: true).write(to: file)
        #expect(MicrophoneLive.read(file)?.muteRead == true)
        try Data(#"{"duration":3,"live":[[0,3]]}"#.utf8).write(to: file)
        #expect(MicrophoneLive.read(file)?.muteRead == nil && MicrophoneLive.read(file)?.followedMute == false)
    }

    @Test("an unchanged meeting is the same bytes every time, so a launch uploads nothing")
    func stableManifest() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let shared = try await item(f)
        let manifest = shared.directory.appending(path: "Meeting.json")
        let first = try Data(contentsOf: manifest)
        #expect(try shared.meeting.encoded() == first)
        let written = try manifest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let relaunched = MeetingSync(stateFile: f.root.appending(path: "owner.json"))
        #expect(try await relaunched.refresh().state.publications.values.first?.restored == nil)
        var again = URL(fileURLWithPath: manifest.path)
        again.removeAllCachedResourceValues()
        #expect(try again.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == written)
    }

    @Test("a provider's conflict copy of the manifest is ours to remove; anything else there is not")
    func conflictCopies() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let shared = try await item(f)
        let copy = shared.directory.appending(path: "Meeting-Alex’s MacBook Pro.json")
        try FileManager.default.copyItem(at: shared.directory.appending(path: "Meeting.json"), to: copy)
        let theirs = shared.directory.appending(path: "Meeting notes.json")
        try Data("{}".utf8).write(to: theirs)
        try f.revise("Monday")
        _ = try await f.owner.refresh()
        #expect(!FileManager.default.fileExists(atPath: copy.path) && FileManager.default.fileExists(atPath: theirs.path))
        await #expect(throws: (any Error).self) { try await f.owner.remove(f.source) }
        try FileManager.default.removeItem(at: theirs)
        try FileManager.default.copyItem(at: shared.directory.appending(path: "Meeting.json"), to: copy)
        #expect(try await f.owner.refresh().state.publications.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: shared.directory.path))
    }

    @Test("a recording still uploading is listed and read; only playing it waits")
    func notUploadedYet() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let shared = try await item(f)
        try FileManager.default.removeItem(at: shared.directory.appending(path: "Recording.mp4"))
        let listed = try #require(try await f.reader.snapshot().meetings.first)
        #expect(listed.meeting.transcript?.utterances.count == 1)
        #expect(CloudFile.download(listed.directory.appending(path: "Recording.mp4")) == .missing)
        await #expect(throws: RecordingShare.Failure.notUploaded) { try await listed.meeting.playableFile(in: listed.directory) }
        try FileManager.default.removeItem(at: shared.directory.appending(path: "Meeting.json"))
        let waiting = try await f.reader.snapshot()
        #expect(waiting.arriving == 1 && waiting.meetings.isEmpty && waiting.failures.isEmpty)
    }

    @Test("the page has everything before any file is opened")
    func entryFromManifest() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let shared = try await item(f)
        let entry = shared.meeting.entry(in: shared.directory)
        #expect(entry.title == "Weekly meeting" && entry.transcript != nil && entry.summary != nil)
        #expect(entry.preview == "Friday" && !entry.hasUnnamedSpeech && entry.duration == 2)
        #expect(entry.bytes >= Int64(f.media.count) && entry.info?.width == 12)
        #expect(shared.meeting.speakers()?.rows.map(\.speaker) == [.named("Recorder")])
        let sources = SharedMeeting.sources(in: shared.directory)
        #expect(sources.map(\.engine) == ["parakeet"] && sources[0].transcript.notes.isEmpty)
        let text = try String(contentsOf: SharedMeeting.sourcesFile(in: shared.directory), encoding: .utf8)
        #expect(!text.contains("Private diagnostic"))
    }

    @Test("a meeting published before tracks were shared reads as it always did")
    func olderManifest() throws {
        let json = #"{"id":"\#(UUID().uuidString)","title":"Old","started":0,"audioOnly":true,"mediaStamp":"1/2","transcript":{"utterances":[{"start":0,"end":4,"text":"Hi","speaker":{"named":{"_0":"Alex"}}}],"engine":"shared","notes":[]}}"#
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = Transcript(utterances: [.init(start: 0, end: 4, text: "Hi", speaker: .named("Alex"))], language: nil, engine: "shared")
        let encoded = String(decoding: try JSONEncoder().encode(transcript), as: UTF8.self)
        let start = try #require(json.range(of: #","transcript":"#))
        try Data((json[..<start.lowerBound] + #","transcript":"# + encoded + "}").utf8).write(to: directory.appendingPathComponent("Meeting.json"))
        let meeting = try SharedMeeting.read(directory)
        let entry = meeting.entry(in: directory)
        #expect(entry.duration == 4 && entry.shared?.tracks.isEmpty == true && entry.shared?.preview == nil)
    }

    @Test("a manifest naming a file outside the meeting is refused")
    func foreignPaths() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let shared = try await item(f)
        var meeting = shared.meeting
        meeting.files = ["../../secret.txt": 4]
        try meeting.encoded().write(to: shared.directory.appending(path: "Meeting.json"))
        #expect(throws: (any Error).self) { try SharedMeeting.read(shared.directory) }
    }

    @Test("a copy has the tracks to listen to and is never transcribed as this Mac's owner", .enabled(if: Muxer.ffmpegPath() != nil))
    func copyKeepsTracks() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try withTracks(f, live: MicrophoneLive(duration: 6, spans: [0..<2, 4..<6], muteRead: true))
        let shared = try await item(f)
        try await shared.meeting.localFiles(in: shared.directory)
        let copy = try shared.meeting.makeCopy(from: shared.directory, in: f.library)
        let plan = OutputPlan(directory: copy)
        #expect(FileManager.default.fileExists(atPath: plan.microphone.path) && FileManager.default.fileExists(atPath: plan.systemAudio.path))
        #expect(TranscriptionService.tracks(in: plan).isEmpty)
    }

    @Test("a team folder can be disconnected, and a meeting taken back out of the library")
    func disconnect() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let shared = try await item(f)
        try await f.reader.addToLibrary(shared.directory)
        try await f.reader.removeFromLibrary(shared.directory)
        #expect(try await f.reader.snapshot().state.linked.isEmpty)
        try await f.reader.addToLibrary(shared.directory)
        try await f.reader.disconnect(f.folder)
        let after = try await f.reader.snapshot()
        #expect(after.meetings.isEmpty && after.state.linked.isEmpty && after.state.folders.isEmpty)
        #expect(FileManager.default.fileExists(atPath: shared.directory.path))
    }

    @Test("one's own meetings are not listed as shared, however their folder is reached")
    func ownMeetings() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try await f.owner.sync(f.source, to: f.folder)
        let alias = f.root.appending(path: "Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.folder)
        try await f.owner.connect(alias)
        #expect(try await f.owner.snapshot().meetings.isEmpty)
    }

    @Test("a sync asked for twice at once makes one copy")
    func concurrent() async throws {
        let f = try Fixture()
        defer { f.clean() }
        async let first: Void = f.owner.sync(f.source, to: f.folder)
        async let second = f.owner.refresh()
        async let third = f.owner.refresh()
        _ = try await (first, second, third)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.folder.path).count == 1)
        #expect(try await f.owner.snapshot().preparing.isEmpty)
    }

    @Test("a recording is up only when every file is, and the providers' progress counts")
    func uploads() {
        #expect(SharedUpload.of([(.uploaded, 10, 0), (.uploaded, 5, 0)]) == .uploaded)
        #expect(SharedUpload.of([(.uploaded, 10, 0), (.uploading, 20, 0.5), (.waiting, 5, 0)]) == .uploading(done: 20, total: 35))
        #expect(SharedUpload.of([(.notCloud, 10, 0)]) == .notCloud)
        #expect(SharedUpload.of([(.uploading, 10, 0), (.failed("Out of space"), 1, 0)]) == .failed("Out of space"))
    }
}
