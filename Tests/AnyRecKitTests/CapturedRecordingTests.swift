import Foundation
import Testing

@testable import AnyRecKit

@Suite("Captured recording")
struct CapturedRecordingTests {
    @Test("publishes complete merges and preserves the previous file on failure",
          .enabled(if: Muxer.ffmpegPath() != nil))
    func publishing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-publish-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try OutputPlan.create(in: root)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Muxer.ffmpegPath()))
        process.arguments = ["-nostdin", "-v", "error", "-f", "lavfi", "-i",
                             "color=c=black:s=16x16:d=0.1", "-c:v", "mpeg4", plan.screen.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let capture = CapturedRecording(summary: RecordingSummary(
            plan: plan, screenFrames: 3, systemAudioSamples: 0, microphoneSamples: 0,
            droppedSamples: 0, systemAudioPeak: -120, microphonePeak: -120, endedEarly: nil))

        let first = await capture.merged(enabled: true)
        guard case .merged(let firstFile) = first.merge else {
            Issue.record("First merge failed: \(first.merge)"); return
        }
        #expect(FileManager.default.fileExists(atPath: firstFile.output.path))
        let second = await capture.merged(enabled: true)
        guard case .merged(let secondFile) = second.merge else {
            Issue.record("Replacement merge failed: \(second.merge)"); return
        }
        let complete = try Data(contentsOf: secondFile.output)
        #expect(!complete.isEmpty)
        try Data("invalid video".utf8).write(to: plan.screen)
        let failed = await capture.merged(enabled: true)
        if case .failed = failed.merge {} else { Issue.record("Expected the invalid source to fail") }
        #expect(try Data(contentsOf: secondFile.output) == complete)
        let files = try FileManager.default.contentsOfDirectory(atPath: plan.directory.path)
        #expect(!files.contains { $0.hasPrefix(".merge-") })
    }
}
