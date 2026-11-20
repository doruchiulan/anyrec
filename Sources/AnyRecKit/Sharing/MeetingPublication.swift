import CryptoKit
import Foundation

public struct MeetingPublication: Codable, Equatable, Sendable {
    public let id: UUID
    public let folder: URL
    let name: String
    public var directory: URL { folder.appendingPathComponent(name, isDirectory: true) }
    var previousFolder: URL?
    var withdrawing = false
    /// What AnyRec wrote into the shared folder, file by file, so a change made there —
    /// by anyone with edit access, or by a sync gone wrong — is noticed and put back. The
    /// owner's recording is never touched by any of it: publishing is one-way. Nil until the
    /// first publish records it, and in older state files.
    var fingerprints: [String: Fingerprint]?
    /// When the shared copy was last put back after a change made there.
    public internal(set) var restored: Date?

    /// One shared file as AnyRec wrote it: its size, and for the small files their digest.
    /// The recording itself is compared by size, so checking never reads or downloads it.
    struct Fingerprint: Codable, Equatable, Sendable {
        let size: Int
        let digest: String?
    }

    init(source: URL, folder: URL) {
        id = UUID()
        self.folder = folder
        name = "Meeting " + RecordingMedia.folderName(title: RecordingInfo.read(source)?.title ?? source.lastPathComponent,
                                        app: nil, started: RecordingLibrary.started(source)) + " " + id.uuidString
    }

    private init(moving old: Self, to folder: URL) {
        id = old.id
        name = old.name
        self.folder = folder
        previousFolder = old.folder
    }

    func moved(to folder: URL) -> Self { Self(moving: self, to: folder) }

    /// The shared folder's files as they are now, in the same terms as `fingerprints`.
    func fingerprints(mediaName: String) -> [String: Fingerprint] {
        var found: [String: Fingerprint] = [:]
        for name in [mediaName, SharedMeeting.manifest, "Summary.md", "Transcript.md"] {
            let url = directory.appendingPathComponent(name)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            let digest = name == mediaName ? nil : (try? Data(contentsOf: url)).map {
                SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
            }
            found[name] = Fingerprint(size: size, digest: digest)
        }
        return found
    }

    /// Makes the shared folder what the owner's recording says it should be: the small files
    /// rewritten wherever their contents differ, the recording copied again when it is
    /// missing, its size is wrong or it is a newer take. Running it on a folder already
    /// right changes nothing, so it is also how a changed or deleted file is put back.
    func publish(from source: URL) throws {
        let fm = FileManager.default
        guard let media = RecordingMedia.merged(in: source) else { throw RecordingShare.Failure.nothingToShare }
        try SharedFiles.check(folder)
        try SharedFiles.check(media)
        try SharedFiles.check(directory)
        let next = try SharedMeeting.snapshot(source, id: id, media: media)
        if fm.fileExists(atPath: directory.path) {
            /// A manifest someone broke reads as nothing: the folder is still ours by its
            /// name, which carries the id.
            let last = try? SharedMeeting.read(directory)
            if let last, last.id != id { throw CocoaError(.fileWriteFileExists) }
            try update(directory, media: media, next: next, last: last)
        } else {
            let stage = folder.appendingPathComponent(".anyrec-" + UUID().uuidString)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: stage) }
            try update(stage, media: media, next: next, last: nil)
            try fm.moveItem(at: stage, to: directory)
        }
    }

    private func update(_ target: URL, media: URL, next: SharedMeeting, last: SharedMeeting?) throws {
        let fm = FileManager.default
        let output = target.appendingPathComponent(next.mediaName)
        try SharedFiles.check(output)
        let size = { (url: URL) in (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1 }
        if last?.mediaStamp != next.mediaStamp || !fm.fileExists(atPath: output.path) || size(output) != size(media) {
            let temp = target.appendingPathComponent(".media-" + UUID().uuidString)
            defer { try? fm.removeItem(at: temp) }
            try fm.copyItem(at: media, to: temp)
            if fm.fileExists(atPath: output.path) { _ = try fm.replaceItemAt(output, withItemAt: temp) }
            else { try fm.moveItem(at: temp, to: output) }
        }
        try SharedFiles.write(next.notes.map { Data($0.utf8) }, to: target.appendingPathComponent("Summary.md"), ifChanged: true)
        try SharedFiles.write(next.transcript.map { Data($0.markdown(title: next.title).utf8) },
                              to: target.appendingPathComponent("Transcript.md"), ifChanged: true)
        try SharedFiles.write(JSONEncoder().encode(next), to: target.appendingPathComponent(SharedMeeting.manifest), ifChanged: true)
    }

    func withdraw(from root: URL) throws {
        let fm = FileManager.default
        try SharedFiles.check(root)
        _ = try fm.contentsOfDirectory(atPath: root.path)
        let target = root.appendingPathComponent(name, isDirectory: true)
        try SharedFiles.check(target)
        guard fm.fileExists(atPath: target.path) else { return }
        let current = try SharedMeeting.read(target)
        guard current.id == id else { throw CocoaError(.fileWriteNoPermission) }
        let owned: Set<String> = [current.mediaName, SharedMeeting.manifest, "Summary.md", "Transcript.md", ".DS_Store"]
        guard Set(try fm.contentsOfDirectory(atPath: target.path)).isSubset(of: owned) else {
            throw RecordingShare.Failure.failed("The shared folder contains additional files. Move them out before removing the meeting.")
        }
        try fm.removeItem(at: target)
    }
}
