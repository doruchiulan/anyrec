import Foundation

public struct SharedMeeting: Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let started: Date
    public let audioOnly: Bool
    public let transcript: Transcript?
    public let summary: Summary?
    public let legacySummary: String?
    let mediaStamp: String

    public var notes: String? { summary?.markdown ?? legacySummary }
    public var mediaName: String { audioOnly ? "Recording.m4a" : "Recording.mp4" }
    static let manifest = "Meeting.json"

    static func snapshot(_ source: URL, id: UUID, media: URL) throws -> Self {
        let info = RecordingInfo.read(source)
        let current = RecordingTranscript.read(in: source)
        var names = current?.voices?.names ?? [:]
        if names[RecordingVoices.meKey] == nil { names[RecordingVoices.meKey] = "Recorder" }
        let transcript = current?.transcript.named(names)
        let summaryURL = TranscriptStore.activeSummary(in: source)
        var summary: Summary?
        var legacy: String?
        if let summaryURL {
            if summaryURL.pathExtension == "json" {
                summary = Summary.read(summaryURL)?.named(names)
                guard summary != nil else { throw CocoaError(.fileReadCorruptFile) }
                summary?.basis = nil
            } else { legacy = try String(contentsOf: summaryURL, encoding: .utf8) }
        }
        if current == nil && TranscriptStore.activeTranscript(in: source) != nil { throw CocoaError(.fileReadCorruptFile) }
        let clean = transcript.map { Transcript(utterances: $0.utterances, language: $0.language, engine: "shared") }
        return Self(id: id, title: info?.title ?? source.lastPathComponent,
                    started: RecordingLibrary.started(source, info: info), audioOnly: media.pathExtension.lowercased() == "m4a",
                    transcript: clean, summary: summary, legacySummary: legacy, mediaStamp: try stamp(media))
    }

    static func stamp(_ file: URL) throws -> String {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values.fileSize ?? 0)/\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    static func read(_ directory: URL) throws -> Self {
        let file = directory.appendingPathComponent(manifest)
        try SharedFiles.requireFile(file)
        let meeting = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard meeting.transcript?.utterances.allSatisfy({ $0.start >= 0 && $0.end >= $0.start && $0.end < 1e10 }) != false
        else { throw CocoaError(.fileReadCorruptFile) }
        guard meeting.summary?.actions.compactMap(\.at).allSatisfy({ $0 >= 0 && $0 < 1e10 }) != false else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return meeting
    }

    public func makeCopy(from directory: URL, in library: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let copyID = UUID().uuidString
        let stage = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: library, create: true)
        defer { try? fm.removeItem(at: stage) }
        let temp = stage.appendingPathComponent(copyID, isDirectory: true)
        let base = RecordingMedia.folderName(title: title, app: nil, started: started)
        let final = library.appendingPathComponent(base + " (Copy " + String(copyID.prefix(8)) + ")", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent(mediaName)
        try SharedFiles.check(directory)
        try SharedFiles.requireFile(file)
        guard try Self.read(directory) == self else { throw CocoaError(.fileReadCorruptFile) }
        try fm.copyItem(at: file, to: temp.appendingPathComponent(mediaName))
        let info = RecordingInfo(title: title, bundleID: nil, width: 0, height: 0, fps: 0, audioOnly: audioOnly,
                                 mergedFile: mediaName, compressed: true, id: copyID, startedAt: started)
        try info.write(to: temp)
        if let transcript {
            let safe = Transcript(utterances: transcript.utterances, language: transcript.language, engine: "shared")
            try TranscriptStore.publish(safe, voices: nil, in: temp)
        }
        if let saved = summary ?? legacySummary.map({ Summary(overview: $0, decisions: [], actions: [], provider: "Shared") }) {
            if let source = TranscriptStore.activeTranscript(in: temp) {
                try TranscriptStore.publishSummary(saved, for: source, names: [:])
            } else {
                try saved.write(to: RecordingLayout(directory: temp).writeURL("summary-shared.json"), names: [:])
            }
        }
        try Data().write(to: RecordingLayout(directory: temp).writeURL("shared-copy"))
        try fm.moveItem(at: temp, to: final)
        return final
    }
}

enum SharedFiles {
    static let fm = FileManager.default

    static func check(_ url: URL) throws {
        guard (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw CocoaError(.fileReadNoPermission) }
    }

    /// `ifChanged` leaves a file that already holds exactly `data` alone, so a repair that
    /// finds nothing wrong writes nothing and starts no upload.
    static func write(_ data: Data?, to url: URL, ifChanged: Bool = false) throws {
        try check(url)
        if let data {
            if ifChanged, (try? Data(contentsOf: url)) == data { return }
            try data.write(to: url, options: .atomic)
        } else if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }
}
