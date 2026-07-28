import Foundation

/// Where each of the three streams lands on disk.
public struct OutputPlan: Sendable, Equatable {
    public let directory: URL
    public let screen: URL
    public let systemAudio: URL
    public let microphone: URL

    public init(directory: URL) {
        self.directory = directory
        screen = directory.appendingPathComponent("screen.mov")
        systemAudio = directory.appendingPathComponent("system-audio.m4a")
        microphone = directory.appendingPathComponent("microphone.m4a")
    }

    public static func folderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "rec-\(formatter.string(from: date))"
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
