import Foundation
import Testing

@testable import SlackRecKit

@Suite("Muxer")
struct MuxerTests {
    private func plan(with tracks: [String]) throws -> OutputPlan {
        let root = URL(filePath: NSTemporaryDirectory())
            .appendingPathComponent("slack-rec-mux-\(UUID().uuidString)")
        let plan = try OutputPlan.create(in: root, named: "call")
        for track in tracks {
            let url = plan.directory.appendingPathComponent(track)
            try Data("x".utf8).write(to: url)
        }
        return plan
    }

    @Test("mixes both audio tracks down against the copied video")
    func bothTracks() throws {
        let plan = try self.plan(with: ["screen.mov", "system-audio.m4a", "microphone.m4a"])
        defer { try? FileManager.default.removeItem(at: plan.directory) }

        let (args, output) = try Muxer.arguments(for: plan)

        #expect(args.contains("-filter_complex"))
        #expect(args.contains("[1:a][2:a]amix=inputs=2:duration=longest:normalize=0[a]"))
        #expect(args.contains("copy"))
        #expect(output.lastPathComponent == "call.mp4")
    }

    @Test("maps a lone audio track directly, without a mix filter")
    func singleTrack() throws {
        let plan = try self.plan(with: ["screen.mov", "system-audio.m4a"])
        defer { try? FileManager.default.removeItem(at: plan.directory) }

        let (args, _) = try Muxer.arguments(for: plan)

        #expect(!args.contains("-filter_complex"))
        #expect(args.contains("1:a"))
    }

    @Test("refuses to mux when no video was captured")
    func withoutVideo() throws {
        let plan = try self.plan(with: ["system-audio.m4a"])
        defer { try? FileManager.default.removeItem(at: plan.directory) }

        #expect(throws: MuxError.self) { try Muxer.arguments(for: plan) }
    }
}
