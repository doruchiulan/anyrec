import AVFoundation
import Foundation
import Testing

@testable import AnyRecKit

/// The real compression, through ffmpeg's x265 and AVFoundation, over a merged file made
/// from a few seconds of generated picture and tone.
@Suite("Compression", .enabled(if: Muxer.ffmpegPath().map(Compression.hasEncoder) == true))
struct CompressionTests {
    private let mergedName = "Design review – Slack – 2026-11-03 10.08.mp4"

    private func ffmpeg(_ args: [String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Muxer.ffmpegPath()))
        process.arguments = ["-nostdin", "-v", "error", "-y"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// A folder after a verified merge: the named file holds the only picture (a mostly
    /// still frame at a generous bitrate, as a call is), `screen.mov` is gone.
    private func merged(seconds: Int = 4, size: String = "320x240", info: RecordingInfo? = nil) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-compress-\(UUID())")
        let directory = root.appendingPathComponent("rec-2026-11-03-100842")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(mergedName)
        try #require(try ffmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=30:duration=\(seconds)",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(seconds)",
            "-c:v", "libx264", "-preset", "ultrafast", "-qp", "0", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-shortest", file.path,
        ]))
        try (info ?? RecordingInfo(title: "Design review", bundleID: "com.tinyspeck.slackmacgap", width: 320, height: 240,
                                   fps: 30, mergedFile: mergedName)).write(to: directory)
        return (root, directory)
    }

    @Test("The merged video is replaced by a smaller HEVC copy with every frame, and marked done")
    func compresses() async throws {
        let (root, directory) = try merged()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directory.appendingPathComponent(mergedName)
        let before = try await MediaFacts.read(file)

        let outcome = try await Compression.compress(directory, using: try #require(Muxer.ffmpegPath()))
        guard case .compressed(let was, let now) = outcome else { Issue.record("not compressed: \(outcome)"); return }
        #expect(now < was)

        let after = try await MediaFacts.read(file)
        let video = try #require(after.video.first)
        #expect(MergeVerification.fourCC(video.codec) == "hvc1")
        #expect(video.frames == before.video.first?.frames)
        #expect(video.width == 320 && video.height == 240)
        #expect(abs((after.audio.first ?? 0) - (before.audio.first ?? 0)) < 0.05)
        #expect(RecordingInfo.read(directory)?.compressed == true)
        #expect(RecordingInfo.read(directory)?.mergedFile == mergedName)
        #expect(Compression.candidate(in: directory) == nil)
        #expect(Compression.leftovers(in: directory).isEmpty)
    }

    @Test("Only a merged video that is the only picture and not yet compressed is a candidate")
    func candidates() throws {
        let (root, directory) = try merged(seconds: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Compression.candidate(in: directory)?.lastPathComponent == mergedName)

        let screen = RecordingLayout(directory: directory).writeURL("screen.mov")
        FileManager.default.createFile(atPath: screen.path, contents: Data())
        #expect(Compression.candidate(in: directory) == nil, "screen.mov is still the master")
        try FileManager.default.removeItem(at: screen)

        var info = try #require(RecordingInfo.read(directory))
        info.compressed = true
        try info.write(to: directory)
        #expect(Compression.candidate(in: directory) == nil)

        try RecordingInfo(title: "Call", bundleID: nil, width: 2, height: 2, fps: 1, audioOnly: true,
                          mergedFile: mergedName).write(to: directory)
        #expect(Compression.candidate(in: directory) == nil, "audio only")
    }

    @Test("Cancelled part-way, the folder is left exactly as it was")
    func cancelled() async throws {
        let (root, directory) = try merged(seconds: 20, size: "1280x720")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directory.appendingPathComponent(mergedName)
        let original = try Data(contentsOf: file)
        let ffmpeg = try #require(Muxer.ffmpegPath())

        let task = Task { try await Compression.compress(directory, using: ffmpeg) }
        try await Task.sleep(for: .milliseconds(800))
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(5), "ffmpeg is stopped at once, not left to finish")
        #expect(try Data(contentsOf: file) == original)
        #expect(RecordingInfo.read(directory)?.compressed == false)
        #expect(Compression.leftovers(in: directory).isEmpty)
    }

    @Test("A result missing frames, at another size, not HEVC or with shorter audio is refused")
    func verification() {
        let reference = MediaFacts.Video(codec: kCMVideoCodecType_H264, width: 1646, height: 1330, frames: 900,
                                         duration: 30, frameDuration: 1.0 / 30)
        let original = MediaFacts(video: [reference], audio: [30.02])
        func result(codec: FourCharCode = kCMVideoCodecType_HEVC, width: Int = 1646, frames: Int = 900, audio: [TimeInterval] = [30.02]) -> MediaFacts {
            MediaFacts(video: [MediaFacts.Video(codec: codec, width: width, height: 1330, frames: frames,
                                                duration: 30, frameDuration: 1.0 / 30)], audio: audio)
        }
        #expect(Compression.problem(with: result(), original: original, reference: reference) == nil)
        #expect(Compression.problem(with: result(frames: 899), original: original, reference: reference) != nil)
        #expect(Compression.problem(with: result(width: 1640), original: original, reference: reference) != nil)
        #expect(Compression.problem(with: result(codec: kCMVideoCodecType_H264), original: original, reference: reference) != nil)
        #expect(Compression.problem(with: result(audio: [28]), original: original, reference: reference) != nil)
        #expect(Compression.problem(with: result(audio: []), original: original, reference: reference) != nil)
    }

    @Test("recording.json written before compression reads as not compressed")
    func olderInfo() throws {
        let json = #"{"title":"Call","width":2,"height":2,"fps":30}"#
        #expect(try JSONDecoder().decode(RecordingInfo.self, from: Data(json.utf8)).compressed == false)
    }
}
