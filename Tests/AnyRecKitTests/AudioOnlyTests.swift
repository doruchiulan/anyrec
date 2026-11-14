import CoreMedia
import Foundation
import ScreenCaptureKit
import Testing

@testable import AnyRecKit

/// A recording with no picture: the window is still picked and captured, but nothing
/// that assumed a `screen.mov` may need one.
@Suite("Audio-only recording")
struct AudioOnlyTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anyrec-audio-only-\(UUID().uuidString)")
            .appendingPathComponent("rec-2026-11-14-101500")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a recording keeps its video unless asked not to")
    func configurationDefault() {
        var configuration = RecordingConfiguration()
        #expect(configuration.video)
        #expect(configuration.options.recordsVideo)
        #expect(CaptureOptions().recordsVideo)

        configuration.video = false
        #expect(!configuration.options.recordsVideo)
    }

    @Test("audio only with both audio tracks off records nothing, and the session refuses it")
    func nothingToRecord() async {
        var configuration = RecordingConfiguration()
        configuration.capture = CaptureChoice(target: .display(index: 0))
        configuration.video = false
        configuration.systemAudio = false
        configuration.microphone = nil
        #expect(!configuration.recordsAnything)
        await #expect(throws: SessionError.self) { _ = try await RecordingSession.start(configuration) }

        configuration.systemAudio = true
        #expect(configuration.recordsAnything)
    }

    @Test("recording.json says it is audio only, and reads back")
    func infoRoundTrip() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let info = RecordingInfo(title: "Weekly", bundleID: "com.microsoft.teams2", width: 1512,
                                 height: 982, fps: 30, audioOnly: true)
        try info.write(to: directory)

        #expect(RecordingInfo.read(directory) == info)
        #expect(RecordingInfo.read(directory)?.audioOnly == true)
    }

    @Test("a recording.json written before the field was kept reads as video")
    func olderInfo() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let older = #"{"title":"Standup","bundleID":"com.tinyspeck.slackmacgap","width":800,"height":600,"fps":30}"#
        try Data(older.utf8).write(to: directory.appendingPathComponent(RecordingInfo.fileName))

        let info = try #require(RecordingInfo.read(directory))
        #expect(!info.audioOnly)
        #expect(info.title == "Standup" && info.width == 800)
    }

    @Test("merges the two audio tracks into an .m4a with no video input or map")
    func mergeBothTracks() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        for track in ["system-audio.m4a", "microphone.m4a"] {
            try Data("x".utf8).write(to: directory.appendingPathComponent(track))
        }
        try RecordingInfo(title: "Call", bundleID: nil, width: 2, height: 2, fps: 1, audioOnly: true)
            .write(to: directory)
        let plan = OutputPlan(directory: directory)

        let job = try await Muxer.job(for: plan)
        let args = Muxer.arguments(for: job, mix: MixPlan(balance: .duckedMicrophone), writingTo: job.output)

        #expect(job.output.pathExtension == "m4a")
        #expect(!args.contains(plan.screen.path))
        #expect(!args.contains { $0.contains(":v") })
        #expect(!args.contains("-c:v"))
        #expect(args.filter { $0 == "-i" }.count == 2)
        let graph = try #require(args.firstIndex(of: "-filter_complex").map { args[$0 + 1] })
        #expect(graph.contains("[1:a][key]" + MixPlan.duck))
        #expect(args.contains("[a]") && args.contains("aac"))
    }

    @Test("a lone audio track is mapped as the first input")
    func mergeOneTrack() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try Data("x".utf8).write(to: directory.appendingPathComponent("microphone.m4a"))

        let job = try await Muxer.job(for: OutputPlan(directory: directory))
        let args = Muxer.arguments(for: job, writingTo: job.output)

        #expect(!args.contains("-filter_complex"))
        #expect(args.contains("0:a"))
        #expect(!args.contains("-c:v"))
    }

    @Test("refuses to merge a folder with no track at all")
    func mergeNothing() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        await #expect(throws: MuxError.self) { try await Muxer.job(for: OutputPlan(directory: directory)) }
    }

    @Test("the library knows an audio-only folder from recording.json, and asks for no still")
    func libraryEntry() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try RecordingInfo(title: "Call", bundleID: nil, width: 2, height: 2, fps: 30, audioOnly: true)
            .write(to: directory)
        for file in ["call.mp4", "system-audio.m4a", "microphone.m4a"] {
            try Data().write(to: directory.appendingPathComponent(file))
        }

        let entry = RecordingLibrary.entry(at: directory)

        #expect(entry.audioOnly)
        #expect(entry.media?.lastPathComponent == "call.mp4")
        #expect(entry.video == nil)
        #expect(entry.tracks == 2)
        #expect(!Thumbnail.wanted(for: entry))
        #expect(await Thumbnail.of(entry) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(Thumbnail.fileName).path))
    }

    @Test("a video recording's merged file is still its video")
    func videoEntry() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try RecordingInfo(title: "Call", bundleID: nil, width: 2, height: 2, fps: 30).write(to: directory)
        for file in ["call.mp4", "screen.mov"] { try Data().write(to: directory.appendingPathComponent(file)) }

        let entry = RecordingLibrary.entry(at: directory)

        #expect(!entry.audioOnly)
        #expect(entry.video?.lastPathComponent == "call.mp4")
        #expect(Thumbnail.wanted(for: entry))
    }

    // MARK: Recorder

    private func recorder(video: Bool) -> Recorder {
        let target = ResolvedTarget(filter: SCContentFilter(), width: 1512, height: 982, describing: "Call")
        return Recorder(options: CaptureOptions(recordsVideo: video), target: target,
                        plan: OutputPlan(directory: URL(fileURLWithPath: "/tmp/anyrec-audio-only-\(UUID())")))
    }

    @Test("screen frames are refused before the clock when video is off, and audio never is")
    func acceptsBuffers() {
        let audioOnly = recorder(video: false)
        #expect(!audioOnly.accepts(.screen, complete: true))
        #expect(audioOnly.accepts(.audio, complete: false))
        #expect(audioOnly.accepts(.microphone, complete: false))

        let video = recorder(video: true)
        #expect(video.accepts(.screen, complete: true))
        #expect(!video.accepts(.screen, complete: false))
    }

    @Test("an audio-only stream asks for the smallest picture, once a second")
    func configuration() {
        let audioOnly = recorder(video: false).makeConfiguration()
        #expect(audioOnly.width == Recorder.audioOnlyFrame && audioOnly.height == Recorder.audioOnlyFrame)
        #expect(audioOnly.minimumFrameInterval == CMTime(value: 1, timescale: 1))
        #expect(audioOnly.capturesAudio && audioOnly.captureMicrophone)

        let video = recorder(video: true).makeConfiguration()
        #expect(video.width == 1512 && video.height == 982)
    }

    /// The clock the participant monitor reads, and the session start every writer shares,
    /// may only come from a buffer that is written. A screen frame in an audio-only
    /// recording must leave both untouched and make no writer.
    @Test("a screen frame in an audio-only recording starts no clock and makes no screen track")
    func screenFrameLeavesClock() throws {
        let recorder = recorder(video: false)
        let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 1), presentationTimeStamp: CMTime(value: 5, timescale: 1),
            decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: nil, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer)
        let frame = try #require(buffer)

        recorder.stream(stream, didOutputSampleBuffer: frame, of: .screen)

        #expect(recorder.timelineTime == nil)
        #expect(recorder.progress().screenFrames == 0)
    }
}
