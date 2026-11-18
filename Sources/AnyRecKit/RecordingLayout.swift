import Foundation

/// Where every file of one recording folder lives. The one place that knows the layout:
///
/// ```
/// <Recording folder>/
///   <merged file>.mp4 | .m4a, Transcript.md, Summary.md
///   Tracks/   microphone.m4a, system-audio.m4a, screen.mov
///   Data/     recording.json, call-participants.json, microphone-live.json, transcription.json
///   Data/Transcripts/   transcript-*, speakers-*, wording-*, summary-* (and older generations)
///   Cache/    mix.json, diarization.json, waveform.json, thumbnail.jpg, mix.wav
/// ```
///
/// Folders made before this kept everything flat. Reads fall back to that (`readURL`,
/// `files(in:)`); writes always go to the new place (`writeURL`). Moving a flat folder
/// into the new layout is `RecordingMigration`'s job and nothing else's.
public struct RecordingLayout: Sendable, Equatable {
    public enum Place: Sendable, Equatable, CaseIterable {
        case top, tracks, data, transcripts, cache

        public var components: [String] {
            switch self {
            case .top: []
            case .tracks: ["Tracks"]
            case .data: ["Data"]
            case .transcripts: ["Data", "Transcripts"]
            case .cache: ["Cache"]
            }
        }
    }

    public static let tracksName = "Tracks"
    public static let dataName = "Data"
    public static let cacheName = "Cache"
    /// The selection of which transcript layers are current. Flat folders called it
    /// `.transcription.json`.
    public static let selectionName = "transcription.json"
    public static let legacySelectionName = ".transcription.json"
    public static let transcriptMarkdown = "Transcript.md"
    public static let summaryMarkdown = "Summary.md"

    public let directory: URL

    public init(directory: URL) {
        self.directory = URL(fileURLWithPath: directory.path, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
    }

    /// The recording folder a file belongs to, whichever subfolder it is in.
    public static func containing(_ file: URL) -> RecordingLayout {
        var parent = file.deletingLastPathComponent()
        if parent.lastPathComponent == "Transcripts", parent.deletingLastPathComponent().lastPathComponent == dataName {
            parent = parent.deletingLastPathComponent().deletingLastPathComponent()
        } else if [tracksName, dataName, cacheName].contains(parent.lastPathComponent) {
            parent = parent.deletingLastPathComponent()
        }
        return RecordingLayout(directory: parent)
    }

    // MARK: Where a name belongs

    public static func place(of name: String) -> Place {
        switch name {
        case "microphone.m4a", "system-audio.m4a", "screen.mov", "microphone-clean.m4a":
            return .tracks
        case "recording.json", "call-participants.json", "microphone-live.json",
             selectionName, legacySelectionName, ".transcription-no-speech.json", "transcription-no-speech.json":
            return .data
        case "mix.json", "diarization.json", "waveform.json", "thumbnail.jpg", "mix.wav":
            return .cache
        case "voices.json":
            return .transcripts
        default:
            let generated = ["transcript-", "speakers-", "wording-", "summary-", "voices-", "review-"]
            if generated.contains(where: name.hasPrefix), ["json", "md", "srt"].contains((name as NSString).pathExtension) {
                return .transcripts
            }
            return .top
        }
    }

    public func folder(_ place: Place) -> URL {
        place.components.reduce(directory) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// The name a file has in the new layout (the selection lost its leading dot).
    static func currentName(_ name: String) -> String {
        switch name {
        case legacySelectionName: selectionName
        case ".transcription-no-speech.json": "transcription-no-speech.json"
        default: name
        }
    }

    /// Where `name` goes in the new layout. No disk access.
    public func url(_ name: String) -> URL {
        let name = Self.currentName(name)
        return folder(Self.place(of: name)).appendingPathComponent(name)
    }

    /// Where a flat folder kept `name`.
    public func legacyURL(_ name: String) -> URL {
        let legacy: String = switch name {
        case Self.selectionName: Self.legacySelectionName
        case "transcription-no-speech.json": ".transcription-no-speech.json"
        default: name
        }
        return directory.appendingPathComponent(legacy)
    }

    /// Where to read `name`: the new place, else the flat one when that is where it is,
    /// else the new place (which then does not exist).
    public func readURL(_ name: String) -> URL {
        let current = url(name)
        if exists(current) { return current }
        let legacy = legacyURL(name)
        return Self.place(of: Self.currentName(name)) != .top && exists(legacy) ? legacy : current
    }

    /// Where to write `name`: always the new place, whose folder is made.
    public func writeURL(_ name: String) -> URL {
        let target = url(name)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        return target
    }

    /// Makes the folders a recording writes into.
    public func prepare(_ places: [Place] = [.tracks, .data]) throws {
        for place in places {
            try FileManager.default.createDirectory(at: folder(place), withIntermediateDirectories: true)
        }
    }

    /// The files of one place, with a flat folder's own counted in under the same rules
    /// as a read: a name present in both is the new one. Nothing is listed twice.
    public func files(in place: Place) -> [URL] {
        let manager = FileManager.default
        /// Rebuilt from the folder asked about, so the URLs are spelled as ours are.
        func list(_ url: URL) -> [URL] {
            ((try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
                .map { url.appendingPathComponent($0.lastPathComponent) }
        }
        var found: [String: URL] = [:]
        for file in list(folder(place)) { found[file.lastPathComponent] = file }
        if place != .top {
            for file in list(directory) where Self.place(of: file.lastPathComponent) == place {
                let name = Self.currentName(file.lastPathComponent)
                if found[name] == nil { found[name] = file }
            }
        }
        return found.values.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Named files

    public var recordingInfo: URL { readURL(RecordingInfo.fileName) }
    public var selection: URL { readURL(Self.selectionName) }

    /// What a voiceprint's origin and older MCP ids call this recording: the `rec-…` id
    /// `recording.json` keeps, else the folder's name.
    public var identity: String { RecordingInfo.read(directory)?.id ?? directory.lastPathComponent }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Folder names

    /// Whether a name could be one of ours: a legacy `rec-` folder or a readable one that
    /// starts with its date.
    public static func looksLikeRecording(_ name: String) -> Bool {
        name.hasPrefix("rec-") || readableDate(fromName: name) != nil
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }

    /// The start a readable name begins with ("2026-11-18 15.29 Title – App"); minute
    /// resolution. Nil for any other name.
    public static func readableDate(fromName name: String) -> Date? {
        guard name.count >= 17 else { return nil }
        let prefix = String(name.prefix(16))
        let separator = name[name.index(name.startIndex, offsetBy: 16)]
        guard separator == " " else { return nil }
        return formatter("yyyy-MM-dd HH.mm").date(from: prefix)
    }

    /// `<root>/<name>` or, when taken, `<name> (2)`, `<name> (3)`… Never an existing path.
    public static func uniqueName(_ name: String, in root: URL, excluding own: URL? = nil) -> String {
        let manager = FileManager.default
        func taken(_ candidate: String) -> Bool {
            let url = root.appendingPathComponent(candidate)
            if let own, own.standardizedFileURL.path == url.standardizedFileURL.path { return false }
            return manager.fileExists(atPath: url.path)
        }
        if !taken(name) { return name }
        var index = 2
        while taken("\(name) (\(index))") { index += 1 }
        return "\(name) (\(index))"
    }
}
