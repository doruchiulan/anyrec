import Foundation
import Testing

@testable import AnyRecKit

@Suite("OutputPlan")
struct OutputPlanTests {
    @Test("names folders from the wall clock")
    func folderName() {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 9
        components.hour = 14
        components.minute = 5
        components.second = 7
        let date = Calendar(identifier: .gregorian).date(from: components)!

        #expect(OutputPlan.folderName(for: date) == "rec-2026-03-09-140507")
    }

    @Test("creates the directory and names the three tracks")
    func createsDirectory() throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appendingPathComponent("anyrec-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try OutputPlan.create(in: root, named: "call")

        #expect(FileManager.default.fileExists(atPath: plan.directory.path))
        #expect(plan.screen.lastPathComponent == "screen.mov")
        #expect(plan.systemAudio.lastPathComponent == "system-audio.m4a")
        #expect(plan.microphone.lastPathComponent == "microphone.m4a")
        #expect(plan.directory.lastPathComponent == "call")
    }

    @Test("capture and library use the same key through an output-folder symlink")
    func directoryIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let physical = root.appendingPathComponent("physical")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let plan = try OutputPlan.create(in: alias, named: "rec-2026-10-23-010000")
        let entry = try #require(RecordingLibrary.entries(in: physical).first)
        #expect(plan.directory == entry.directory)
        #expect(Set([plan.directory]).contains(entry.directory))
        #expect(OutputPlan(directory: URL(fileURLWithPath: entry.directory.path)).directory == entry.directory)
    }
}
