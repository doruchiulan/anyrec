import CoreMedia
import Foundation
import Testing

@testable import AnyRecKit

@Suite("Muxer")
struct MuxerTests {
    private func plan(with tracks: [String]) throws -> OutputPlan {
        let root = URL(filePath: NSTemporaryDirectory())
            .appendingPathComponent("anyrec-mux-\(UUID().uuidString)")
        let plan = try OutputPlan.create(in: root, named: "call")
        for track in tracks {
            let url = plan.layout.writeURL(track)
            try Data("x".utf8).write(to: url)
        }
        return plan
    }

    private static let h264 = MediaFacts.Video(
        codec: kCMVideoCodecType_H264, width: 1600, height: 1000, frames: 300, duration: 10, frameDuration: 1.0 / 30)

    private func job(_ plan: OutputPlan, video: URL?, reference: MediaFacts.Video? = h264,
                     audio: [URL]) -> MergeJob {
        MergeJob(video: video, reference: video == nil ? nil : reference, audio: audio,
                 output: plan.directory.appendingPathComponent("out.mp4"))
    }

    @Test("mixes both audio tracks down against the copied video")
    func bothTracks() throws {
        let plan = try self.plan(with: [])
        defer { try? FileManager.default.removeItem(at: plan.directory) }

        let args = Muxer.arguments(for: job(plan, video: plan.screen, audio: [plan.systemAudio, plan.microphone]),
                                   writingTo: plan.directory.appendingPathComponent(".merge.mp4"))

        #expect(args.contains("-filter_complex"))
        #expect(args.contains("[1:a][2:a]amix=inputs=2:duration=longest:normalize=0[a]"))
        #expect(args.contains("copy"))
        #expect(args.contains("0:v:0"))
        #expect(!args.contains("-tag:v"))
        #expect(args.last?.hasSuffix(".merge.mp4") == true)
    }

    @Test("tags copied HEVC hvc1, which AVFoundation plays and hev1 is not")
    func hevc() throws {
        let plan = try self.plan(with: [])
        defer { try? FileManager.default.removeItem(at: plan.directory) }
        let hevc = MediaFacts.Video(codec: kCMVideoCodecType_HEVC, width: 2, height: 2, frames: 1, duration: 1, frameDuration: 1)

        let args = Muxer.arguments(for: job(plan, video: plan.screen, reference: hevc, audio: [plan.microphone]),
                                   writingTo: plan.directory.appendingPathComponent(".merge.mp4"))

        let tag = try #require(args.firstIndex(of: "-tag:v"))
        #expect(args[tag + 1] == "hvc1")
    }

    @Test("holds the microphone under the call when it bleeds")
    func bleeding() throws {
        let plan = try self.plan(with: [])
        defer { try? FileManager.default.removeItem(at: plan.directory) }

        let args = Muxer.arguments(for: job(plan, video: plan.screen, audio: [plan.systemAudio, plan.microphone]),
                                   mix: MixPlan(balance: .duckedMicrophone), writingTo: plan.screen)

        let graph = try #require(args.firstIndex(of: "-filter_complex").map { args[$0 + 1] })
        #expect(graph.contains("[2:a][key]" + MixPlan.duck))
    }

    @Test("maps a lone audio track directly, without a mix filter")
    func singleTrack() throws {
        let plan = try self.plan(with: [])
        defer { try? FileManager.default.removeItem(at: plan.directory) }

        let args = Muxer.arguments(for: job(plan, video: plan.screen, audio: [plan.systemAudio]), writingTo: plan.screen)

        #expect(!args.contains("-filter_complex"))
        #expect(args.contains("1:a"))
    }

    @Test("without a picture, makes an audio-only merge rather than refusing")
    func withoutVideo() async throws {
        let plan = try self.plan(with: ["system-audio.m4a"])
        defer { try? FileManager.default.removeItem(at: plan.directory) }

        let job = try await Muxer.job(for: plan)
        let args = Muxer.arguments(for: job, writingTo: job.output)

        #expect(job.video == nil)
        /// No `recording.json` to keep a name in, so the merge keeps the name readers find.
        #expect(job.output.lastPathComponent == "call.mp4")
        #expect(args.contains("0:a"))
        #expect(!args.contains { $0.hasPrefix("0:v") })
    }

    @Test("names an audio-only merge from recording.json, as an .m4a")
    func namedAudioOnly() async throws {
        let plan = try self.plan(with: ["system-audio.m4a", "microphone.m4a"])
        defer { try? FileManager.default.removeItem(at: plan.directory) }
        try RecordingInfo(title: "Weekly sync | Microsoft Teams", bundleID: "com.microsoft.teams2",
                          width: 2, height: 2, fps: 1, audioOnly: true).write(to: plan.directory)

        let job = try await Muxer.job(for: plan)

        #expect(job.output.pathExtension == "m4a")
        #expect(job.output.lastPathComponent.hasPrefix("Weekly sync – Microsoft Teams – "))
    }

    @Test("a stored name is kept by a later merge")
    func keepsStoredName() async throws {
        let plan = try self.plan(with: ["system-audio.m4a", "Kept – Slack – 2026-01-02 03.04.m4a"])
        defer { try? FileManager.default.removeItem(at: plan.directory) }
        try RecordingInfo(title: "Renamed since", bundleID: nil, width: 2, height: 2, fps: 1, audioOnly: true,
                          mergedFile: "Kept – Slack – 2026-01-02 03.04.m4a").write(to: plan.directory)

        let job = try await Muxer.job(for: plan)

        #expect(job.output.lastPathComponent == "Kept – Slack – 2026-01-02 03.04.m4a")
    }

    @Test("an unreadable screen.mov stops the merge before anything is written")
    func unreadableScreen() async throws {
        let plan = try self.plan(with: ["screen.mov", "system-audio.m4a"])
        defer { try? FileManager.default.removeItem(at: plan.directory) }

        await #expect(throws: MuxError.self) { try await Muxer.job(for: plan) }
    }
}
