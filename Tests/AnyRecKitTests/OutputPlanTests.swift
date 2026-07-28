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
}
