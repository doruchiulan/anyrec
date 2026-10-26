import Foundation

/// What a recording was pointed at, written beside the tracks when it starts: the window's
/// title, the app that owned it, and the picture's size. The tracks hold none of this, and
/// without it a library can only call a recording by the time it began.
public struct RecordingInfo: Sendable, Equatable, Codable {
    public static let fileName = "recording.json"

    public let title: String
    /// Nil for a display, which belongs to no app.
    public let bundleID: String?
    public let width: Int
    public let height: Int
    public let fps: Int

    public init(title: String, bundleID: String?, width: Int, height: Int, fps: Int) {
        self.title = title
        self.bundleID = bundleID
        self.width = width
        self.height = height
        self.fps = fps
    }

    /// The registry's name for the app, else nil: a bundle id is not something to show.
    public var appName: String? {
        bundleID.flatMap { id in CallApps.known.first { $0.bundleID == id }?.name }
    }

    /// Recorded in a known call app, so it is a call rather than any window.
    public var isCall: Bool { bundleID.map(CallApps.isKnown) ?? false }

    public static func read(_ directory: URL) -> RecordingInfo? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName))
        else { return nil }
        return try? JSONDecoder().decode(RecordingInfo.self, from: data)
    }

    public func write(to directory: URL) throws {
        try JSONEncoder().encode(self)
            .write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
