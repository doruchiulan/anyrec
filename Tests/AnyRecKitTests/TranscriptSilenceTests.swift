import Foundation
import Testing

@testable import AnyRecKit

@Suite("Recordings without speech")
struct TranscriptSilenceTests {
    @Test("no speech survives a library reload and is invalidated when audio changes")
    func persists() throws {
        let plan = try fixture()
        defer { try? FileManager.default.removeItem(at: plan.directory) }
        #expect(!RecordingLibrary.entry(at: plan.directory).noSpeechDetected)
        try TranscriptStore.recordNoSpeech(in: plan.directory)
        #expect(RecordingLibrary.entry(at: plan.directory).noSpeechDetected)
        try Data(repeating: 0, count: 3_072).write(to: plan.microphone)
        #expect(!RecordingLibrary.entry(at: plan.directory).noSpeechDetected)
    }

    @Test("a successfully published transcript clears the no-speech outcome")
    func written() throws {
        let plan = try fixture()
        defer { try? FileManager.default.removeItem(at: plan.directory) }
        try TranscriptStore.recordNoSpeech(in: plan.directory)
        let transcript = Transcript(utterances: [Utterance(start: 0, end: 1, text: "Heard this", speaker: .me)],
                                    language: "en", engine: "whisper")
        try TranscriptStore.publish(transcript, voices: nil, in: plan.directory)
        #expect(!RecordingLibrary.entry(at: plan.directory).noSpeechDetected)
    }

    private func fixture() throws -> OutputPlan {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-no-speech-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plan = OutputPlan(directory: folder)
        try Data(repeating: 0, count: 2_048).write(to: plan.microphone)
        return plan
    }
}
