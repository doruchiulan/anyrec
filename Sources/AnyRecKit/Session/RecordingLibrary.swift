import AVFoundation
import Foundation

/// One finished recording as it lies on disk: what it is called, when it began, and which
/// of the things a recording can leave behind are actually there.
public struct LibraryEntry: Sendable, Equatable, Identifiable {
    public let directory: URL
    public let started: Date
    public let duration: TimeInterval
    public let bytes: Int64
    /// The merged file, else the screen track; nil when neither was kept.
    public let video: URL?
    public let tracks: Int
    public let transcript: URL?
    public let summary: URL?
    /// Voices in the transcript that nobody has put a name to yet.
    public let unnamedVoices: Int
    /// What it was pointed at; nil for a recording made before this was kept.
    public let info: RecordingInfo?
    /// A line of what was said, for a list row: the summary's opening sentence when there
    /// is one, else the transcript's first words. Nil before either exists.
    public let preview: String?
    public let revision: Date?
    public let noSpeechDetected: Bool

    public var id: URL { directory }
    public var name: String { directory.lastPathComponent }
    /// The window's title when there is one, else the folder's name.
    public var title: String { info?.title ?? name }
}

/// Every recording under the output root, newest first. The terminal's `transcribe` and
/// `speakers` find one folder; the app's library wants all of them.
public enum RecordingLibrary {
    public static func entries(in root: URL) -> [LibraryEntry] {
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { $0.lastPathComponent.hasPrefix("rec-") && isDirectory($0) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(entry)
    }

    /// Bytes under the root, for the sidebar's storage line.
    public static func size(of entries: [LibraryEntry]) -> Int64 {
        entries.reduce(0) { $0 + $1.bytes }
    }

    public static func entry(at directory: URL) -> LibraryEntry {
        let plan = OutputPlan(directory: directory)
        let directory = plan.directory
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(Int64(0)) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let merged = directory.appendingPathComponent("call.mp4")
        let video = [merged, plan.screen].first { exists($0) }
        let tracks = [plan.screen, plan.systemAudio, plan.microphone].filter(exists).count

        let transcript = TranscriptStore.activeTranscript(in: directory)
        let summary = TranscriptStore.activeSummary(in: directory)
        let voicesURL = TranscriptStore.voicesURL(in: directory)
        let voices = voicesURL.flatMap { RecordingVoices.read($0) }

        return LibraryEntry(
            directory: directory, started: started(directory),
            duration: duration(of: [video, plan.systemAudio, plan.microphone]),
            bytes: bytes, video: video, tracks: tracks, transcript: transcript,
            summary: summary, unnamedVoices: voices?.unnamed.count ?? 0,
            info: RecordingInfo.read(directory), preview: preview(summary: summary, transcript: transcript),
            revision: TranscriptStore.revision(of: [transcript, summary, voicesURL]),
            noSpeechDetected: TranscriptStore.noSpeechDetected(in: directory))
    }

    /// Short enough to read in one glance; a list row truncates whatever is left.
    static func preview(summary: URL?, transcript: URL?) -> String? {
        if let summary, summary.pathExtension == "json", let overview = Summary.read(summary)?.overview {
            return firstSentence(of: overview)
        }
        guard let transcript, let lines = Transcript.read(transcript)?.utterances, !lines.isEmpty
        else { return nil }
        var text = ""
        for line in lines where text.count < 160 {
            text += (text.isEmpty ? "" : " ") + line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : String(text.prefix(160))
    }

    static func firstSentence(of text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = text.firstIndex(where: { ".!?".contains($0) }) else { return text }
        return String(text[...end])
    }

    /// The folder name carries the start; the creation date covers one renamed by hand.
    public static func started(_ directory: URL) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        if let date = formatter.date(from: String(directory.lastPathComponent.dropFirst(4))) {
            return date
        }
        let created = try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate
        return created ?? .distantPast
    }

    /// The longest of the files that exist: the tracks run side by side, so the longest
    /// is the recording.
    private static func duration(of files: [URL?]) -> TimeInterval {
        files.compactMap { $0 }.filter(exists)
            .map { CMTimeGetSeconds(AVURLAsset(url: $0).duration) }
            .filter { $0.isFinite }.max() ?? 0
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }
}
