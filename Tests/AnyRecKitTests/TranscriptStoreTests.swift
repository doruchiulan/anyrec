import Foundation
import Testing

@testable import AnyRecKit

@Suite("Transcript generations")
struct TranscriptStoreTests {
    @Test("switching engines selects the new transcript and its voices without overwriting the old version")
    func switchEngine() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try TranscriptStore.publish(transcript("whisper", "Original"),
                                              voices: RecordingVoices(voices: []), in: folder)
        let oldData = try Data(contentsOf: old[2])
        let summary = TranscriptStore.summaryDestination(for: old[2])
        try Summary(overview: "Old summary", decisions: [], actions: [], provider: "test").write(to: summary)
        #expect(try TranscriptStore.selectSummary(summary, for: old[2]))
        let next = try TranscriptStore.publish(transcript("parakeet", "Replacement"), voices: nil, in: folder)
        let entry = RecordingLibrary.entry(at: folder)
        #expect(entry.transcript == next[2])
        #expect(Transcript.read(try #require(entry.transcript))?.engine == "parakeet")
        #expect(entry.summary == nil)
        #expect(RecordingVoices.read(in: folder) == nil)
        #expect(try Data(contentsOf: old[2]) == oldData)
        #expect(try !TranscriptStore.selectSummary(summary, for: old[2]))
        #expect(RecordingLibrary.entry(at: folder).transcript == next[2])
    }

    @Test("regenerating the same engine produces a fresh active version")
    func sameEngine() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try TranscriptStore.publish(transcript("whisper", "First"), voices: nil, in: folder)
        let next = try TranscriptStore.publish(transcript("whisper", "Next"), voices: nil, in: folder)
        #expect(first[2] != next[2])
        #expect(RecordingLibrary.entry(at: folder).transcript == next[2])
        #expect(Transcript.read(first[2])?.plainText.contains("First") == true)
    }

    @Test("a partially written generation fails without changing the active transcript or leaving output files")
    func failure() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try TranscriptStore.publish(transcript("whisper", "Keep this"), voices: nil, in: folder)
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let maximumEngine = String(repeating: "x", count: 255 - (old[0].lastPathComponent.utf8.count - "whisper".count))
        #expect(throws: (any Error).self) {
            try TranscriptStore.publish(transcript(maximumEngine, "Fail"), voices: nil, in: folder)
        }
        #expect(TranscriptStore.activeTranscript(in: folder) == old[2])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before)
    }

    @Test("uncommitted generation files cannot replace a legacy transcript")
    func uncommitted() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = try TranscriptionService.write(transcript("whisper", "Legacy"), into: folder, named: "transcript-whisper")
        _ = try TranscriptionService.write(transcript("parakeet", "Uncommitted"), into: folder,
                                           named: "transcript-parakeet-\(UUID())")
        #expect(TranscriptStore.activeTranscript(in: folder) == legacy[2])
    }

    @Test("legacy transcript and voices are pinned before replacement and stale summaries stay with the old generation")
    func legacy() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try TranscriptionService.write(transcript("whisper", "Legacy"), into: folder, named: "transcript-whisper")
        try RecordingVoices(voices: []).write(to: folder.appendingPathComponent(RecordingVoices.fileName))
        try TranscriptStore.pinSelection(in: folder)
        #expect(TranscriptStore.activeTranscript(in: folder) == files[2])
        #expect(RecordingVoices.read(in: folder) != nil)
        _ = try TranscriptStore.publish(transcript("parakeet", "New"), voices: nil, in: folder)
        #expect(RecordingVoices.read(in: folder) == nil)
        #expect(FileManager.default.fileExists(atPath: files[2].path))
    }

    @Test("merged audio is available to transcription when the separate tracks are absent")
    func mergedSource() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plan = OutputPlan(directory: folder)
        let merged = folder.appendingPathComponent("call.mp4")
        try Data(repeating: 0, count: 2_048).write(to: merged)
        #expect(TranscriptionService.tracks(in: plan).map(\.url) == [merged])
        try Data(repeating: 0, count: 2_048).write(to: plan.microphone)
        #expect(TranscriptionService.tracks(in: plan).map(\.url) == [plan.microphone])
    }

    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-transcript-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return OutputPlan(directory: folder).directory
    }

    private func transcript(_ engine: String, _ text: String) -> Transcript {
        Transcript(utterances: [Utterance(start: 0, end: 1, text: text, speaker: .me)], language: "en", engine: engine)
    }
}
