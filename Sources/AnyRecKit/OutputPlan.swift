import Foundation

extension String {
    public var expandingTilde: String {
        hasPrefix("~") ? NSString(string: self).expandingTildeInPath : self
    }
}

/// Where each of the three streams lands on disk, and what was learned alongside them.
public struct OutputPlan: Sendable, Equatable {
    public let directory: URL
    public let screen: URL
    public let systemAudio: URL
    public let microphone: URL
    /// When the call could hear the microphone. Absent when nothing watched.
    public let microphoneLive: URL
    /// The same microphone through macOS voice processing, echo cancelled, recorded beside
    /// the raw track. Absent when it was switched off or could not run.
    public let cleanMicrophone: URL

    public static let cleanMicrophoneName = "microphone-clean.m4a"

    public init(directory: URL) {
        let directory = URL(fileURLWithPath: directory.path, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        self.directory = directory
        screen = directory.appendingPathComponent("screen.mov")
        systemAudio = directory.appendingPathComponent("system-audio.m4a")
        microphone = directory.appendingPathComponent("microphone.m4a")
        microphoneLive = directory.appendingPathComponent("microphone-live.json")
        cleanMicrophone = directory.appendingPathComponent(Self.cleanMicrophoneName)
    }

    public static func folderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "rec-\(formatter.string(from: date))"
    }

    /// The start a `rec-<timestamp>` folder name carries; nil for any other name.
    public static func date(fromFolderName name: String) -> Date? {
        guard name.hasPrefix("rec-") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: String(name.dropFirst(4)))
    }

    /// Creates `<root>/rec-<timestamp>` on disk and returns the plan for it.
    public static func create(
        in root: URL, named name: String? = nil, at date: Date = Date()
    ) throws -> OutputPlan {
        let directory = root.appendingPathComponent(name ?? folderName(for: date))
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return OutputPlan(directory: directory)
    }
}
