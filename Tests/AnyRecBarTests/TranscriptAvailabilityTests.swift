import Foundation
import Testing

@testable import AnyRecBar
@testable import AnyRecKit

@Suite("Transcript availability")
@MainActor
struct TranscriptAvailabilityTests {
    @Test("a saved no-speech outcome blocks generation after reload until the audio changes")
    func noSpeech() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-availability-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plan = OutputPlan(directory: folder)
        try Data(repeating: 0, count: 2_048).write(to: plan.microphone)
        let controller = RecordingController(completedSetup: true)
        #expect(controller.canTranscribe(RecordingLibrary.entry(at: folder)))
        try TranscriptStore.recordNoSpeech(in: folder)
        #expect(!controller.canTranscribe(RecordingLibrary.entry(at: folder)))
        #expect(controller.processingMessage(for: plan.directory) == "No speech detected.")
        try Data(repeating: 0, count: 3_072).write(to: plan.microphone)
        #expect(controller.canTranscribe(RecordingLibrary.entry(at: folder)))
        #expect(controller.processingMessage(for: plan.directory) == nil)
    }
}
