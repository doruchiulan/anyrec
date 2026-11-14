import AVFoundation
import Foundation
import Testing

@testable import AnyRecKit

/// The real merge, through ffmpeg and AVFoundation, over a few seconds of generated
/// picture and tone: the named file replaces `screen.mov`, and merging again without
/// `screen.mov` keeps every frame.
@Suite("Merge replaces screen.mov", .enabled(if: Muxer.ffmpegPath() != nil))
struct MergeIntegrationTests {
    private static let frames = 90

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

    /// A folder named like a real one, with three seconds of 30 fps picture, two tones and
    /// a `recording.json`; `video` picks the encoder, and nil means none could be used.
    private func recording(video codec: [String] = ["-c:v", "mpeg4"]) throws -> (OutputPlan, URL)? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-merge-\(UUID())")
        let plan = try OutputPlan.create(in: root, named: "rec-2026-11-03-100842")
        guard try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=64x48:rate=30:duration=3"] + codec
                         + ["-frames:v", "\(Self.frames)", plan.screen.path]) else {
            try? FileManager.default.removeItem(at: root)
            return nil
        }
        for (url, tone) in [(plan.systemAudio, 440), (plan.microphone, 660)] {
            try #require(try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=\(tone):sample_rate=48000:duration=3",
                                     "-c:a", "aac", url.path]))
        }
        try RecordingInfo(title: "Design review - Acme - 2 new items - Slack", bundleID: "com.tinyspeck.slackmacgap",
                          width: 64, height: 48, fps: 30).write(to: plan.directory)
        return (plan, root)
    }

    private func capture(_ plan: OutputPlan) -> CapturedRecording {
        CapturedRecording(summary: RecordingSummary(
            plan: plan, screenFrames: Self.frames, systemAudioSamples: 100, microphoneSamples: 100,
            droppedSamples: 0, systemAudioPeak: -12, microphonePeak: -12, endedEarly: nil))
    }

    private func merge(_ plan: OutputPlan) async throws -> MuxOutcome {
        let outcome = await capture(plan).merged(enabled: true)
        guard case .merged(let file) = outcome.merge else {
            throw MuxError.unverified("merge did not succeed: \(outcome.merge)")
        }
        return file
    }

    private func leftovers(in plan: OutputPlan) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: plan.directory.path).filter { $0.hasPrefix(".merge-") }
    }

    @Test("the named file replaces screen.mov with every frame, and a second merge keeps them")
    func replacesAndRemerges() async throws {
        let (plan, root) = try #require(try recording())
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = "Design review - Acme – Slack – 2026-11-03 10.08.mp4"

        let first = try await merge(plan)

        #expect(first.output.lastPathComponent == expected)
        #expect(first.replaced.map(\.lastPathComponent) == ["screen.mov"])
        #expect(!FileManager.default.fileExists(atPath: plan.screen.path))
        #expect(RecordingInfo.read(plan.directory)?.mergedFile == expected)
        #expect(RecordingMedia.playable(in: plan.directory) == first.output)
        #expect(RecordingMedia.video(in: plan.directory) == first.output)
        let facts = try await MediaFacts.read(first.output)
        #expect(facts.video.count == 1 && facts.video.first?.frames == Self.frames)
        #expect(facts.audio.count == 1 && abs((facts.audio.first ?? 0) - 3) < 0.25)

        /// Again, with only the merged file to take the picture from — a retried job, or a
        /// new mix decision.
        let second = try await merge(plan)

        #expect(second.output == first.output)
        #expect(second.replaced.isEmpty)
        let again = try await MediaFacts.read(second.output)
        #expect(again.video.count == 1 && again.video.first?.frames == Self.frames)
        #expect(again.audio.count == 1)
        #expect(try leftovers(in: plan).isEmpty)
        #expect(RecordingLibrary.entry(at: plan.directory).tracks == 3)
    }

    @Test("a merge that fails leaves screen.mov and recording.json as they were")
    func failureKeepsScreen() async throws {
        let (plan, root) = try #require(try recording())
        defer { try? FileManager.default.removeItem(at: root) }
        /// A microphone track that is not audio: ffmpeg refuses it after reading the picture.
        try Data("not audio".utf8).write(to: plan.microphone)
        let before = try Data(contentsOf: plan.directory.appendingPathComponent(RecordingInfo.fileName))

        let outcome = await capture(plan).merged(enabled: true)

        if case .failed = outcome.merge {} else { Issue.record("expected a failed merge, got \(outcome.merge)") }
        #expect(FileManager.default.fileExists(atPath: plan.screen.path))
        #expect(try Data(contentsOf: plan.directory.appendingPathComponent(RecordingInfo.fileName)) == before)
        #expect(RecordingMedia.playable(in: plan.directory) == plan.screen)
        #expect(try leftovers(in: plan).isEmpty)
    }

    @Test("an older folder's call.mp4 and screen.mov are both replaced by the named file once it is verified")
    func olderFolder() async throws {
        let (plan, root) = try #require(try recording())
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = plan.directory.appendingPathComponent("call.mp4")
        try #require(try ffmpeg(["-i", plan.screen.path, "-i", plan.systemAudio.path, "-map", "0:v", "-map", "1:a",
                                 "-c", "copy", legacy.path]))

        let file = try await merge(plan)

        #expect(file.output.lastPathComponent.hasSuffix("2026-11-03 10.08.mp4"))
        #expect(Set(file.replaced.map(\.lastPathComponent)) == ["screen.mov", "call.mp4"])
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try await MediaFacts.read(file.output).video.first?.frames == Self.frames)
    }

    @Test("copied HEVC keeps its hvc1 tag, so the master stays playable in AVFoundation")
    func hevc() async throws {
        guard let (plan, root) = try recording(video: ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1"]) else {
            return /// No VideoToolbox HEVC encoder here; the arguments test covers the flag.
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = try #require(try await MediaFacts.read(plan.screen).video.first)
        try #require(reference.frames == Self.frames)

        let file = try await merge(plan)

        let video = try #require(try await MediaFacts.read(file.output).video.first)
        #expect(MergeVerification.fourCC(video.codec) == "hvc1")
        #expect(video.frames == Self.frames)
    }
}
