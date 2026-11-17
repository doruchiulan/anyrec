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
    /// No video was kept: the window was captured for its audio, title, participants and
    /// mute button only. False for a file written before this was recorded, all of which
    /// had video.
    public let audioOnly: Bool
    /// The merged file's name in this folder, written once a merge has been verified —
    /// "Design review – Slack – 2026-11-03 10.08.mp4". Nil before any merge and in files
    /// written before merged files were named, whose merge is `call.mp4`. Read through
    /// `RecordingMedia`, which falls back when the named file is not there.
    public var mergedFile: String?
    /// When each output's buffers were stamped and arrived, and the audio devices in use,
    /// written when capture stops. Nil in files written before this was recorded and for a
    /// recording whose capture never finished.
    public var timing: CaptureTiming?
    /// The merged file's video has been through `Compression` (or was found not worth
    /// it), so it is not compressed again. False in files written before compression.
    public var compressed: Bool

    public init(
        title: String, bundleID: String?, width: Int, height: Int, fps: Int, audioOnly: Bool = false,
        mergedFile: String? = nil, timing: CaptureTiming? = nil, compressed: Bool = false
    ) {
        self.title = title
        self.bundleID = bundleID
        self.width = width
        self.height = height
        self.fps = fps
        self.audioOnly = audioOnly
        self.mergedFile = mergedFile
        self.timing = timing
        self.compressed = compressed
    }

    private enum CodingKeys: String, CodingKey {
        case title, bundleID, width, height, fps, audioOnly, mergedFile, timing, compressed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        fps = try container.decode(Int.self, forKey: .fps)
        audioOnly = try container.decodeIfPresent(Bool.self, forKey: .audioOnly) ?? false
        mergedFile = try container.decodeIfPresent(String.self, forKey: .mergedFile)
        /// Evidence, never needed to read a recording: a file it cannot be read from is
        /// read without it.
        timing = try? container.decodeIfPresent(CaptureTiming.self, forKey: .timing)
        compressed = try container.decodeIfPresent(Bool.self, forKey: .compressed) ?? false
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
