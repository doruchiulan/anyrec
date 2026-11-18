import AVFoundation
import Foundation
import Testing

@testable import AnyRecKit

@Suite("Sharing a recording", .enabled(if: Muxer.ffmpegPath() != nil))
struct RecordingShareTests {
    private let mergedName = "Design review – Slack – 2026-11-18 10.08.mp4"

    private func ffmpeg(_ args: [String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Muxer.ffmpegPath()))
        process.arguments = ["-nostdin", "-v", "error", "-y"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// A recording in the current layout: a merged video, recording.json and a transcript.
    private func recording(transcript: Bool = true) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-share-\(UUID())")
        let directory = root.appendingPathComponent("2026-11-18 10.08 Design review – Slack")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(try ffmpeg([
            "-f", "lavfi", "-i", "testsrc=size=64x48:rate=30:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3",
            "-c:v", "mpeg4", "-c:a", "aac", "-shortest",
            directory.appendingPathComponent(mergedName).path,
        ]))
        try RecordingInfo(title: "Design review - Slack", bundleID: "com.tinyspeck.slackmacgap", width: 64, height: 48,
                          fps: 30, mergedFile: mergedName).write(to: directory)
        if transcript {
            let lines = [
                Utterance(start: 0.2, end: 1.2, text: "Can we ship on Friday?", speaker: .voice("A")),
                Utterance(start: 1.4, end: 2.6, text: "Friday works.", speaker: .me),
            ]
            _ = try TranscriptStore.publish(Transcript(utterances: lines, language: "en", engine: "parakeet"),
                                            voices: nil, in: directory)
        }
        return (root, directory)
    }

    @Test("The shared video carries the transcript as captions and the title, frame for frame, and the original is untouched")
    func captionsAndTitle() async throws {
        let (root, directory) = try recording()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = directory.appendingPathComponent(mergedName)
        let before = try Data(contentsOf: original)

        let set = try await RecordingShare.prepare(directory)
        #expect(set.name == "2026-11-18 10.08 Design review – Slack")
        #expect(set.files.map(\.lastPathComponent) == [mergedName, "Transcript.md"])
        let shared = try #require(set.files.first)
        #expect(shared != original, "a copy, in Cache/Share")
        #expect(shared.path.contains("/Cache/Share/"))
        #expect(try Data(contentsOf: original) == before)

        let asset = AVURLAsset(url: shared)
        let kinds = try await asset.load(.tracks).map(\.mediaType)
        #expect(kinds.contains(.video) && kinds.contains(.audio))
        #expect(kinds.contains(.subtitle) || kinds.contains(.text), "captions track: \(kinds)")
        let title = try await asset.load(.commonMetadata).first { $0.commonKey == .commonKeyTitle }
        #expect(try await title?.load(.stringValue) == "Design review")
        let frames = try await MediaFacts.read(shared).video.first?.frames
        #expect(frames == (try await MediaFacts.read(original).video.first?.frames))
    }

    @Test("A second share reuses the copy until the transcript changes")
    func reuse() async throws {
        let (root, directory) = try recording()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(try await RecordingShare.prepare(directory).files.first)
        let made = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date
        let again = try #require(try await RecordingShare.prepare(directory).files.first)
        #expect(try FileManager.default.attributesOfItem(atPath: again.path)[.modificationDate] as? Date == made)

        try await Task.sleep(for: .milliseconds(1100))
        let renamed = [Utterance(start: 0.2, end: 1.2, text: "Can we ship on Friday?", speaker: .voice("A"))]
        _ = try TranscriptStore.publish(Transcript(utterances: renamed, language: "en", engine: "whisper"), voices: nil, in: directory)
        let remade = try #require(try await RecordingShare.prepare(directory).files.first)
        #expect(try FileManager.default.attributesOfItem(atPath: remade.path)[.modificationDate] as? Date != made)
    }

    @Test("With no transcript the merged file itself is shared")
    func noTranscript() async throws {
        let (root, directory) = try recording(transcript: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try await RecordingShare.prepare(directory)
        #expect(set.files == [directory.appendingPathComponent(mergedName)])
    }

    @Test("Synced folders are found and a set is copied under AnyRec/<recording>")
    func cloudFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent("Library/CloudStorage/OneDrive-Blueprint"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/CloudStorage/OneDrive-Personal"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/CloudStorage/GoogleDrive-me"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"), withIntermediateDirectories: true)
        let folders = CloudFolder.available(home: home)
        #expect(folders.map(\.name) == ["OneDrive – Blueprint", "OneDrive", "iCloud Drive"])

        let file = home.appendingPathComponent("Summary.md")
        try Data("notes".utf8).write(to: file)
        let set = RecordingShare.Set(files: [file], name: "2026-11-18 10.08 Design review – Slack")
        let saved = try folders[0].save(set)
        #expect(saved.path.hasSuffix("OneDrive-Blueprint/AnyRec/2026-11-18 10.08 Design review – Slack"))
        #expect(fm.fileExists(atPath: saved.appendingPathComponent("Summary.md").path))
        _ = try folders[0].save(set)
    }
}
