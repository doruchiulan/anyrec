import CryptoKit
import Foundation

public struct MeetingPublication: Codable, Equatable, Sendable {
    public let id: UUID
    public let folder: URL
    let name: String
    public var directory: URL { folder.appendingPathComponent(name, isDirectory: true) }
    /// Where it was before a move, in state files from versions that had Move to…; the
    /// next pass removes it from there.
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

    /// The shared folder's files as they are now, in the same terms as `fingerprints`. A
    /// small file the provider has taken off this Mac is compared by size alone: reading it
    /// would download it, on every check.
    func fingerprints(of names: some Sequence<String>) -> [String: Fingerprint] {
        var found: [String: Fingerprint] = [:]
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let size = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            let digest = Self.isLarge(name) || CloudFile.isDataless(url) ? nil : (try? Data(contentsOf: url)).map {
                SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
            }
            found[name] = Fingerprint(size: size, digest: digest)
        }
        return found
    }

    private static func isLarge(_ name: String) -> Bool { ["mp4", "m4a", "jpg"].contains((name as NSString).pathExtension) }

    /// Something in the shared folder is not what AnyRec wrote: changed, deleted, or the
    /// whole meeting gone. Never true before the first publication was recorded.
    var isTampered: Bool {
        guard let recorded = fingerprints else { return false }
        let present = fingerprints(of: recorded.keys)
        return recorded.contains { name, was in
            guard let now = present[name], now.size == was.size else { return true }
            guard let a = now.digest, let b = was.digest else { return false }
            return a != b
        }
    }

    /// Where every published file stands with its cloud provider, taken together.
    /// Nil before its first copy is made.
    public func uploadStatus(fractions: [URL: Double] = [:]) -> SharedUpload? {
        guard let fingerprints else { return nil }
        return .of(fingerprints.map { name, file in
            let url = directory.appendingPathComponent(name)
            return (CloudFile.upload(url), Int64(file.size), fractions[url] ?? 0)
        })
    }

    /// The published files' locations, for following their upload.
    public var files: [URL] { (fingerprints ?? [:]).keys.map { directory.appendingPathComponent($0) } }

    /// The microphone is published only where its mute was followed.
    public var sharesMicrophone: Bool { fingerprints?[SharedMeeting.microphoneTrack] != nil }
    public var sharesTracks: Bool { fingerprints?[SharedMeeting.callTrack] != nil || sharesMicrophone }

    /// Makes the shared folder what the owner's recording says it should be: the small files
    /// rewritten wherever their contents differ, the recording and its tracks copied again
    /// when missing, the wrong size or a newer take. Running it on a folder already right
    /// changes nothing, so it is also how a changed or deleted file is put back. Returns
    /// what it wrote, for `fingerprints`.
    func publish(from source: URL) throws -> [String: Fingerprint] {
        let fm = FileManager.default
        guard let media = RecordingMedia.merged(in: source) else { throw RecordingShare.Failure.nothingToShare }
        guard fm.fileExists(atPath: folder.path) else { throw RecordingShare.Failure.folderUnavailable(folder.lastPathComponent) }
        try SharedFiles.check(folder)
        try SharedFiles.check(media)
        try SharedFiles.check(directory)
        let next = try SharedMeeting.snapshot(source, id: id, media: media)
        let files: [String]
        if fm.fileExists(atPath: directory.path) {
            /// A manifest someone broke reads as nothing: the folder is still ours by its
            /// name, which carries the id.
            let last = try? SharedMeeting.read(directory)
            if let last, last.id != id { throw CocoaError(.fileWriteFileExists) }
            removeConflictCopies()
            files = try update(directory, source: source, media: media, next: next, last: last)
        } else {
            /// Made whole outside the folder and moved in at once: staged inside it, the
            /// provider uploaded the half-made meeting as well.
            let stage = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
            defer { try? fm.removeItem(at: stage) }
            let target = stage.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            files = try update(target, source: source, media: media, next: next, last: nil)
            try fm.moveItem(at: target, to: directory)
        }
        return fingerprints(of: files)
    }

    private func update(_ target: URL, source: URL, media: URL, next: SharedMeeting, last: SharedMeeting?) throws -> [String] {
        let fm = FileManager.default
        var next = next
        var sizes: [String: Int64] = [:]
        var stamps: [String: String] = [:]
        let size = { (url: URL) in (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } }

        /// One large file, made by `make` only when the last one is not it any more.
        func place(_ name: String, current: Bool, make: (URL) throws -> Void) throws {
            let output = target.appendingPathComponent(name)
            try SharedFiles.check(output)
            if !current || !fm.fileExists(atPath: output.path) {
                let stage = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
                defer { try? fm.removeItem(at: stage) }
                try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temp = stage.appendingPathComponent((name as NSString).lastPathComponent)
                try make(temp)
                if fm.fileExists(atPath: output.path) { _ = try fm.replaceItemAt(output, withItemAt: temp) }
                else { try fm.moveItem(at: temp, to: output) }
            }
            sizes[name] = Int64(size(output) ?? 0)
        }
        func text(_ name: String, _ data: Data?) throws {
            try SharedFiles.write(data, to: target.appendingPathComponent(name), ifChanged: true)
            if let data { sizes[name] = Int64(data.count) }
        }

        let output = target.appendingPathComponent(next.mediaName)
        try place(next.mediaName, current: last?.mediaStamp == next.mediaStamp && size(output) == size(media)) {
            try fm.copyItem(at: media, to: $0)
        }
        for track in SharedTrack.all(in: source) {
            stamps[track.name] = track.stamp
            let intact = last?.files?[track.name] == size(target.appendingPathComponent(track.name)).map(Int64.init)
            do { try place(track.name, current: last?.trackStamps?[track.name] == track.stamp && intact, make: track.make) } catch {
                /// The recording is worth sharing without one of its tracks; the next
                /// publication tries it again.
                stamps[track.name] = nil
                sizes[track.name] = nil
            }
        }
        /// A track that may no longer be shared, or is gone from the recording.
        for name in [SharedMeeting.callTrack, SharedMeeting.microphoneTrack] where sizes[name] == nil {
            try SharedFiles.write(nil, to: target.appendingPathComponent(name))
        }
        let still = RecordingLayout(directory: source).readURL(Thumbnail.fileName)
        try text(SharedMeeting.previewName, next.audioOnly ? nil : try? Data(contentsOf: still))
        try text("Summary.md", next.notes.map { Data($0.utf8) })
        try text("Transcript.md", next.transcript.map { Data($0.markdown(title: next.title).utf8) })
        let sources = SharedSource.all(in: source)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try text(SharedMeeting.sourcesName, sources.isEmpty ? nil : try encoder.encode(sources))
        next.sourceCount = sources.isEmpty ? nil : sources.count
        next.files = sizes
        next.trackStamps = stamps
        let manifest = try next.encoded()
        try SharedFiles.write(manifest, to: target.appendingPathComponent(SharedMeeting.manifest), ifChanged: true)
        return Array(sizes.keys) + [SharedMeeting.manifest]
    }

    /// What a provider keeps beside a file two Macs wrote at once ("Meeting-Alex's MacBook.json",
    /// "Meeting 2.json"). Only a manifest whose contents say it is this meeting's is one of
    /// ours; anything else in the folder was put there by someone.
    private func conflictCopies(in target: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
        return names.filter { $0 != SharedMeeting.manifest && $0.hasPrefix("Meeting") && $0.hasSuffix(".json") }
            .map(target.appendingPathComponent)
            .filter { file in
                struct Identity: Decodable { let id: UUID; let mediaStamp: String }
                guard (try? SharedFiles.requireFile(file)) != nil, let data = try? Data(contentsOf: file) else { return false }
                return (try? JSONDecoder().decode(Identity.self, from: data))?.id == id
            }
    }

    private func removeConflictCopies() {
        for file in conflictCopies(in: directory) { try? FileManager.default.removeItem(at: file) }
    }

    func withdraw(from root: URL) throws {
        let fm = FileManager.default
        try SharedFiles.check(root)
        guard fm.fileExists(atPath: root.path) else { throw RecordingShare.Failure.folderUnavailable(root.lastPathComponent) }
        _ = try fm.contentsOfDirectory(atPath: root.path)
        let target = root.appendingPathComponent(name, isDirectory: true)
        try SharedFiles.check(target)
        guard fm.fileExists(atPath: target.path) else { return }
        let current = try SharedMeeting.read(target)
        guard current.id == id else { throw CocoaError(.fileWriteNoPermission) }
        let owned = Set(current.published + conflictCopies(in: target).map(\.lastPathComponent)
            + (fingerprints.map { Array($0.keys) } ?? []))
        let extras = Self.contents(of: target).filter { !owned.contains($0) && !$0.hasSuffix(".DS_Store") }
        guard extras.isEmpty else {
            throw RecordingShare.Failure.failed("The shared folder contains additional files. Move them out before removing the meeting.")
        }
        try fm.removeItem(at: target)
    }

    /// Every file in the meeting's folder, by path within it.
    private static func contents(of target: URL) -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: target.path)) ?? []).flatMap { name -> [String] in
            var directory: ObjCBool = false
            let url = target.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return [name] }
            let inside = contents(of: url)
            return inside.isEmpty && name != "Tracks" ? [name] : inside.map { name + "/" + $0 }
        }
    }
}
