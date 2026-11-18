import Foundation

extension String {
    public var expandingTilde: String {
        hasPrefix("~") ? NSString(string: self).expandingTildeInPath : self
    }
}

/// Where each of the three streams lands on disk, and what was learned alongside them.
/// Paths come from `RecordingLayout`: a flat (older) folder's files are found where they
/// are, anything not on disk yet is where the new layout puts it.
public struct OutputPlan: Sendable, Equatable {
    public let directory: URL
    public let screen: URL
    public let systemAudio: URL
    public let microphone: URL
    /// When the call could hear the microphone. Absent when nothing watched.
    public let microphoneLive: URL

    public var layout: RecordingLayout { RecordingLayout(directory: directory) }

    public init(directory: URL) {
        let layout = RecordingLayout(directory: directory)
        self.directory = layout.directory
        screen = layout.readURL("screen.mov")
        systemAudio = layout.readURL("system-audio.m4a")
        microphone = layout.readURL("microphone.m4a")
        microphoneLive = layout.readURL("microphone-live.json")
    }

    /// The old-style identity, `rec-YYYY-MM-DD-HHMMSS`: what `recording.json` keeps as `id`
    /// and what a folder without a readable name is called.
    public static func folderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "rec-\(formatter.string(from: date))"
    }

    /// The start a folder name carries: a `rec-<timestamp>` id, or a readable name's date
    /// prefix; nil for any other name.
    public static func date(fromFolderName name: String) -> Date? {
        if name.hasPrefix("rec-") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            return formatter.date(from: String(name.dropFirst(4).prefix(17)))
        }
        return RecordingLayout.readableDate(fromName: name)
    }

    /// Creates the recording's folder on disk, with the folders it writes into, and returns
    /// the plan for it. Named `name`, else from `title` and `app` as "2026-11-18 15.29 Title
    /// – App" (made unique in `root`), else the old `rec-` id.
    public static func create(
        in root: URL, named name: String? = nil, at date: Date = Date(),
        title: String? = nil, app: String? = nil
    ) throws -> OutputPlan {
        let chosen: String
        if let name {
            chosen = name
        } else if let title {
            chosen = RecordingLayout.uniqueName(
                RecordingMedia.folderName(title: title, app: app, started: date), in: root)
        } else {
            chosen = folderName(for: date)
        }
        let directory = root.appendingPathComponent(chosen)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let plan = OutputPlan(directory: directory)
        try plan.layout.prepare()
        return plan
    }
}
