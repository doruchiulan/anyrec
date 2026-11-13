import Foundation

public struct MeetingReader: Sendable {
    let root: URL

    public init(root: URL) throws {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &directory), directory.boolValue else {
            throw MeetingReadError.unavailable("The recordings folder does not exist or is not a directory.")
        }
        self.root = resolved
    }

    func directories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent.hasPrefix("rec-") && safeDirectory($0) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func directory(_ id: String) throws -> URL {
        guard id.hasPrefix("rec-"), id == (id as NSString).lastPathComponent, !id.contains("\\"),
              safeDirectory(root.appendingPathComponent(id)) else {
            throw MeetingReadError.invalid("Unknown meeting ID. Use an ID returned by list_meetings or search_meetings.")
        }
        return root.appendingPathComponent(id)
    }

    private func safeDirectory(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path
            && url.deletingLastPathComponent().standardizedFileURL.path == root.path
            && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func snapshot(_ id: String) throws -> MeetingSnapshot {
        try MeetingSnapshot(directory: directory(id))
    }
}

struct MeetingSnapshot {
    let directory: URL
    var info: RecordingInfo?
    var transcript: Transcript?
    var voices: RecordingVoices?
    var summary: Summary?
    var summaryMarkdown: String?
    var observed: CallParticipants?
    var generation: String?
    var warnings: [String] = []

    init(directory: URL) throws {
        self.directory = directory
        info = read(RecordingInfo.self, file: RecordingInfo.fileName)
        let selectionURL = directory.appendingPathComponent(".transcription.json")
        if FileManager.default.fileExists(atPath: selectionURL.path) {
            if let selection = read(TranscriptStore.Selection.self, file: ".transcription.json") {
                load(transcript: selection.transcript, voices: selection.voices, summary: selection.summary)
            } else {
                warnings.append("The selected generation is unavailable; older generations were not substituted.")
            }
        } else {
            let file = TranscriptStore.activeTranscript(in: directory)
            let engine = file.flatMap { read(Transcript.self, file: $0.lastPathComponent) }?.engine
            let summaryFile = legacySummary(engine: engine)
            load(transcript: file?.lastPathComponent, voices: RecordingVoices.fileName, summary: summaryFile)
        }
        observed = read(CallParticipants.self, file: CallParticipants.fileName)
    }

    private mutating func load(transcript file: String?, voices voiceFile: String?, summary summaryFile: String?) {
        generation = file
        if let file { transcript = read(Transcript.self, file: file) }
        if let voiceFile { voices = read(RecordingVoices.self, file: voiceFile) }
        if let summaryFile {
            if summaryFile.hasSuffix(".json") { summary = read(Summary.self, file: summaryFile) }
            else if summaryFile.hasSuffix(".md"), let data = data(summaryFile) {
                summaryMarkdown = String(data: data, encoding: .utf8)
            }
        }
    }

    private func legacySummary(engine: String?) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { name in
            guard name.hasPrefix("summary-"), ["json", "md"].contains((name as NSString).pathExtension) else { return false }
            if let engine { return (name as NSString).deletingPathExtension == "summary-\(engine)" }
            return UUID(uuidString: String((name as NSString).deletingPathExtension.suffix(36))) == nil
        }.max { ($0.hasSuffix(".json") ? 1 : 0, $0) < ($1.hasSuffix(".json") ? 1 : 0, $1) }
    }

    private mutating func read<T: Decodable>(_ type: T.Type, file: String) -> T? {
        guard let data = data(file) else { return nil }
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            warnings.append("Unreadable \(file).")
            return nil
        }
        return value
    }

    private mutating func data(_ file: String) -> Data? {
        let url = directory.appendingPathComponent(file)
        guard !file.isEmpty, file != ".", file != "..", file == (file as NSString).lastPathComponent,
              !file.contains("\\"), url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
            warnings.append("Blocked a file outside this meeting.")
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            warnings.append("Not a regular file: \(file).")
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            warnings.append("Cannot read \(file).")
            return nil
        }
        defer { try? handle.close() }
        let maximum = 64 * 1_024 * 1_024
        guard let data = try? handle.read(upToCount: maximum + 1), data.count <= maximum else {
            warnings.append("Cannot read \(file) within the 64 MiB file limit.")
            return nil
        }
        return data
    }

    var participants: MeetingParticipants {
        let saved = voices?.voices.map {
            MeetingParticipants.Voice(label: "Speaker \($0.letter)", name: $0.name, identityEvidence: $0.identityEvidence)
        } ?? []
        let labels = Set(transcript?.utterances.map(\.speaker) ?? [])
        let extra = labels.filter { speaker in !saved.contains { $0.label == speaker.label } }.map { speaker in
            let name: String? = if case .named(let value) = speaker { value } else { nil }
            return MeetingParticipants.Voice(label: speaker.label, name: name, identityEvidence: nil)
        }
        return MeetingParticipants(meetingID: directory.lastPathComponent,
            observedInCall: Array(Set(observed?.observations.flatMap(\.participants) ?? [])).sorted(),
            transcriptSpeakers: (saved + extra).sorted { $0.label < $1.label }, warnings: warnings)
    }

    var details: MeetingDetails {
        MeetingDetails(id: directory.lastPathComponent, title: info?.title ?? directory.lastPathComponent,
            startedAt: RecordingLibrary.started(directory), app: info?.appName,
            transcriptAvailable: transcript != nil, summaryAvailable: summary != nil || summaryMarkdown != nil,
            transcriptGeneration: generation, participantNames: participants.names, warnings: warnings)
    }
}
