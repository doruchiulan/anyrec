import Foundation
import Testing

@testable import AnyRecKit

@Suite("Recording library")
struct RecordingLibraryTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anyrec-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("lists recording folders newest first and ignores everything else")
    func ordering() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["rec-2026-10-20-090000", "rec-2026-10-21-101500", "notes"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let entries = RecordingLibrary.entries(in: root)

        #expect(entries.map(\.name) == ["rec-2026-10-21-101500", "rec-2026-10-20-090000"])
    }

    @Test("reads the start from the folder name")
    func started() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("rec-2026-10-21-101500")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: RecordingLibrary.entry(at: folder).started)

        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 21)
        #expect(parts.hour == 10 && parts.minute == 15)
    }

    @Test("finds the newest transcript and the summary beside it")
    func artefacts() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("rec-2026-10-21-101500")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["transcript-apple.json", "transcript-whisper.json", "summary-whisper.md"] {
            try Data().write(to: folder.appendingPathComponent(file))
        }

        let entry = RecordingLibrary.entry(at: folder)

        #expect(entry.transcript?.lastPathComponent == "transcript-whisper.json")
        #expect(entry.summary?.lastPathComponent == "summary-whisper.md")
        #expect(entry.video == nil && entry.tracks == 0)
    }

    @Test("the waveform is read from its cache, and a cache of the wrong size is ignored")
    func waveformCache() throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent(Waveform.fileName)
        let stored = (0..<Waveform.columns).map { Float($0) / Float(Waveform.columns) }
        try JSONEncoder().encode(stored).write(to: cache)

        #expect(Waveform.of(folder, duration: 60) == stored)

        try JSONEncoder().encode([Float(1)]).write(to: cache)
        /// No audio to decode either, so a stale cache comes back empty rather than wrong.
        #expect(Waveform.of(folder, duration: 60).isEmpty)
    }
}
