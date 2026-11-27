import Foundation

/// One synced meeting as a team folder holds it, read from its `Meeting.json`. Everything a
/// page shows before anything is played is in here or beside it in small files, so opening
/// a meeting never waits for the recording:
///
/// ```
/// Meeting <date> <title> <id>/
///   Recording.mp4 | .m4a     the merged recording
///   Tracks/                  Call audio.m4a, and Microphone.m4a silenced where it was muted
///   Meeting.json             this
///   Sources.json             what each engine wrote, for View Sources
///   Preview.jpg, Summary.md, Transcript.md
/// ```
///
/// Voiceprints, the voice library, the raw microphone, the call window's polls and the
/// diagnostics stay with the owner. Everything after `mediaStamp` is absent from meetings
/// published before 0.12 and reads as nil; older versions ignore it.
public struct SharedMeeting: Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let started: Date
    public let audioOnly: Bool
    public let transcript: Transcript?
    public let summary: Summary?
    public let legacySummary: String?
    let mediaStamp: String
    /// Who synced it.
    public var sharedBy: String? = nil
    public var bundleID: String? = nil
    public var width: Int? = nil
    public var height: Int? = nil
    public var fps: Int? = nil
    public var duration: TimeInterval? = nil
    public var waveform: [Float]? = nil
    /// People the call window listed who said nothing.
    public var silent: [String]? = nil
    /// The call track's lag behind the microphone, to play the two in line.
    var callOffset: TrackOffset? = nil
    public var reviewedBy: SummaryProvider? = nil
    public var reviewFailures: [String]? = nil
    /// How many transcripts `Sources.json` holds.
    public var sourceCount: Int? = nil
    /// Every published file but this one, by path, with its size: what to expect, however
    /// much of it has arrived.
    public internal(set) var files: [String: Int64]? = nil
    /// What each rendered or copied track was made from.
    var trackStamps: [String: String]? = nil

    public var notes: String? { summary?.markdown ?? legacySummary }
    public var mediaName: String { audioOnly ? "Recording.m4a" : "Recording.mp4" }
    static let manifest = "Meeting.json"
    static let sourcesName = "Sources.json"
    static let previewName = "Preview.jpg"
    static let callTrack = "Tracks/Call audio.m4a"
    static let microphoneTrack = "Tracks/Microphone.m4a"
    static let maximumDuration = 1e10

    /// Same contents, same bytes: keys in one order. In whatever order each launch hashed
    /// them, an unchanged meeting was rewritten and uploaded again at every launch, and two
    /// AnyRecs writing it at once left OneDrive's conflict copies behind.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func snapshot(_ source: URL, id: UUID, media: URL, library: VoiceLibrary = .load()) throws -> Self {
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
        let duration = RecordingLibrary.duration(of: [media])
        var meeting = Self(
            id: id, title: info?.title ?? source.lastPathComponent,
            started: RecordingLibrary.started(source, info: info), audioOnly: media.pathExtension.lowercased() == "m4a",
            transcript: clean, summary: summary, legacySummary: legacy, mediaStamp: try stamp(media))
        /// The Mac account's full name, the same on every meeting someone shares: the name a
        /// transcript or the voice library calls them can differ from call to call.
        meeting.sharedBy = Self.sharerName()
        meeting.bundleID = info?.bundleID
        meeting.width = info?.width
        meeting.height = info?.height
        meeting.fps = info?.fps
        if duration > 0 {
            meeting.duration = duration
            let peaks = Waveform.of(source, duration: duration)
            if !peaks.isEmpty { meeting.waveform = peaks }
        }
        meeting.silent = RecordingSpeakers.read(in: source, library: library)?.silentPeople
        meeting.callOffset = MixDecision.read(in: source)?.systemAudioOffset
        meeting.reviewedBy = current?.reviewProvider
        if let failures = current?.reviewFailures, !failures.isEmpty { meeting.reviewFailures = failures }
        return meeting
    }

    /// The files this version of the meeting is made of, whether or not they have arrived.
    var published: [String] {
        [mediaName, Self.manifest] + (files.map { Array($0.keys) } ?? ["Summary.md", "Transcript.md"])
            .filter { $0 != mediaName }
    }

    /// Where the call's track is moved to play in line with the microphone and the picture.
    public var callShift: TrackShift { callOffset?.shift ?? .zero }

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
        /// Written by someone else's Mac, and some of it ends up in paths and layouts.
        guard meeting.duration.map({ $0 >= 0 && $0 < maximumDuration }) != false,
              meeting.width.map({ $0 >= 0 && $0 < 100_000 }) != false, meeting.height.map({ $0 >= 0 && $0 < 100_000 }) != false,
              meeting.waveform?.allSatisfy(\.isFinite) != false,
              meeting.files?.allSatisfy({ known.contains($0.key) && $0.value >= 0 }) != false
        else { throw CocoaError(.fileReadCorruptFile) }
        return meeting
    }

    /// Every path a meeting may publish. Nothing else in a manifest is followed.
    static let known: Set<String> = ["Recording.mp4", "Recording.m4a", callTrack, microphoneTrack, sourcesName, previewName,
                                     "Summary.md", "Transcript.md"]

    public static func sharerName(_ full: String = NSFullUserName()) -> String? {
        let name = full.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
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
        let info = RecordingInfo(title: title, bundleID: bundleID, width: width ?? 0, height: height ?? 0, fps: fps ?? 0,
                                 audioOnly: audioOnly, mergedFile: mediaName, compressed: true, id: copyID, startedAt: started)
        try info.write(to: temp)
        let layout = RecordingLayout(directory: temp)
        for (name, target) in [(Self.callTrack, "system-audio.m4a"), (Self.microphoneTrack, "microphone.m4a")] where files?[name] != nil {
            let track = directory.appendingPathComponent(name)
            try SharedFiles.requireFile(track)
            try fm.copyItem(at: track, to: layout.writeURL(target))
        }
        if let callOffset {
            MixDecision(basis: .of(OutputPlan(directory: temp)), bleeding: false, microphoneLoudness: nil,
                        systemAudioLoudness: nil, systemAudioOffset: callOffset).write(in: temp)
        }
        if let waveform, waveform.count == Waveform.columns {
            try? JSONEncoder().encode(waveform).write(to: layout.writeURL(Waveform.fileName))
        }
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

/// The files one shared meeting offers, where they are in the team folder.
public struct SharedOrigin: Sendable, Equatable {
    public let id: UUID
    public let sharedBy: String?
    public let media: URL
    public let mediaBytes: Int64?
    /// Published tracks only; nil for a meeting without them.
    public let callAudio: URL?
    public let microphone: URL?
    public let callShift: TrackShift
    public let preview: URL?

    /// The separate tracks, which are fetched only when one is switched off.
    public var tracks: [URL] { [callAudio, microphone].compactMap { $0 } }
}

extension SharedMeeting {
    public func origin(in directory: URL) -> SharedOrigin {
        let file = { (name: String) in files?[name].map { _ in directory.appendingPathComponent(name) } }
        let media = directory.appendingPathComponent(mediaName)
        /// Its size, which a file that is only in the cloud still has.
        let bytes = files?[mediaName] ?? (try? media.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
        return SharedOrigin(
            id: id, sharedBy: sharedBy, media: media, mediaBytes: bytes,
            callAudio: file(Self.callTrack), microphone: file(Self.microphoneTrack), callShift: callShift,
            preview: file(Self.previewName))
    }

    /// The meeting as the library lists its own recordings, worked out from the manifest
    /// alone: probing the files would fetch them.
    public func entry(in directory: URL) -> LibraryEntry {
        let origin = origin(in: directory)
        let info = RecordingInfo(title: title, bundleID: bundleID, width: width ?? 0, height: height ?? 0, fps: fps ?? 0,
                                 audioOnly: audioOnly, mergedFile: mediaName, startedAt: started)
        let manifest = directory.appendingPathComponent(Self.manifest)
        let lines = transcript?.utterances ?? []
        return LibraryEntry(
            directory: directory, started: started, duration: duration ?? lines.map(\.end).max() ?? 0,
            bytes: files?.values.reduce(0, +) ?? origin.mediaBytes ?? 0, media: origin.media, audioOnly: audioOnly, tracks: origin.tracks.count + 1,
            transcript: transcript == nil ? nil : manifest, summary: notes == nil ? nil : manifest,
            unnamedVoices: 0, hasUnclaimedLines: false, info: info,
            preview: summary.map { RecordingLibrary.firstSentence(of: $0.overview) }
                ?? (lines.isEmpty ? nil : String(lines.prefix(8).map(\.text).joined(separator: " ").prefix(160))),
            revision: nil, noSpeechDetected: false, shared: origin)
    }

    /// Who spoke, for the page's People: names, talk time and samples, nothing to answer.
    public func speakers() -> RecordingSpeakers? {
        guard let transcript else { return nil }
        let window = silent.flatMap { $0.isEmpty ? nil : CallParticipants(observations: [.init(at: 0, source: "", participants: $0, speaking: [])]) }
        return RecordingSpeakers.build(lines: transcript.utterances, voices: nil, suggestions: [], corrections: [],
                                       participants: window, info: nil, library: VoiceLibrary())
    }

    /// What each engine wrote, when the meeting carries it. Reads a file: off the main
    /// thread, once it is here.
    public static func sources(in directory: URL) -> [SharedSource] {
        let file = directory.appendingPathComponent(sourcesName)
        guard (try? SharedFiles.requireFile(file)) != nil, let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([SharedSource].self, from: data)) ?? []
    }

    public static func sourcesFile(in directory: URL) -> URL { directory.appendingPathComponent(sourcesName) }
}

/// One engine's transcript as it is shared: its words and times, without its diagnostics.
public struct SharedSource: Codable, Equatable, Sendable {
    public let engine: String
    public let written: Date
    public let compared: Bool
    public let transcript: Transcript

    /// The selected transcript and the ones it was compared with. Earlier versions, which
    /// the owner replaced, stay with the owner.
    static func all(in source: URL) -> [SharedSource] {
        TranscriptStore.sources(in: source).compactMap { version in
            guard version.role != .earlier, let transcript = Transcript.read(version.url) else { return nil }
            return SharedSource(engine: version.engine, written: version.written, compared: version.role == .compared,
                                transcript: Transcript(utterances: transcript.utterances, language: transcript.language, engine: version.engine))
        }
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
