import Foundation
import Testing

@testable import AnyRecKit

/// A manual check of the merge on a copy of a real recording, run only when
/// `ANYREC_MERGE_CHECK_DIR` names the copy's folder. It merges that folder in place, so
/// it refuses anything under an `AnyRec Recordings` folder: point it at a copy.
@Suite("Real recording merge check")
struct RealRecordingMergeCheck {
    static let folder = ProcessInfo.processInfo.environment["ANYREC_MERGE_CHECK_DIR"]

    @Test("merges a copied recording and reports what it made", .enabled(if: folder != nil && Muxer.ffmpegPath() != nil))
    func check() async throws {
        let directory = URL(fileURLWithPath: try #require(Self.folder))
        try #require(!directory.standardizedFileURL.path.contains("AnyRec Recordings"), "point this at a copy")
        let plan = OutputPlan(directory: directory)
        let size = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }
        let before = try FileManager.default.contentsOfDirectory(at: plan.directory, includingPropertiesForKeys: nil)
        let started = Date()

        let outcome = try await Muxer.mux(plan)

        print("merge-check: took \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        for file in before { print("merge-check: before \(file.lastPathComponent) \(size(file))") }
        let after = try FileManager.default.contentsOfDirectory(at: plan.directory, includingPropertiesForKeys: nil)
        for file in after { print("merge-check: after \(file.lastPathComponent) \(size(file))") }
        print("merge-check: output \(outcome.output.lastPathComponent)")
        print("merge-check: replaced \(outcome.replaced.map(\.lastPathComponent))")
        print("merge-check: recording.json mergedFile \(RecordingInfo.read(plan.directory)?.mergedFile ?? "nil")")
        #expect(RecordingMedia.playable(in: plan.directory) == outcome.output)
    }
}
