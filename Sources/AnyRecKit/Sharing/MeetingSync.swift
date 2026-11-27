import Foundation

public struct SharedLibraryItem: Equatable, Sendable, Identifiable {
    public let directory: URL
    public let meeting: SharedMeeting
    public var id: URL { directory }
}

public struct MeetingSyncState: Codable, Equatable, Sendable {
    /// Each synced recording's shared copies, one per folder: the sync location's, and any
    /// other folder it was also synced to. Files from before held one copy a recording, as
    /// `publications`; it becomes the first.
    public fileprivate(set) var publications: [URL: [MeetingPublication]] = [:]
    /// The sync location: one folder, chosen from a recording's Sync button or Settings, where
    /// recordings are synced and where colleagues' meetings are read from. Nil until one is
    /// chosen, and again once disconnected. Files from before kept it as `lastFolder` beside a
    /// separate list of connected `folders`; the first of those stands in when it was never set.
    public fileprivate(set) var location: URL?

    public init() {}

    private enum CodingKeys: String, CodingKey { case copies, publications, location, lastFolder, folders }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        publications = try container.decodeIfPresent([URL: [MeetingPublication]].self, forKey: .copies)
            ?? container.decodeIfPresent([URL: MeetingPublication].self, forKey: .publications)?.mapValues { [$0] } ?? [:]
        location = try container.decodeIfPresent(URL.self, forKey: .location)
            ?? container.decodeIfPresent(URL.self, forKey: .lastFolder)
            ?? container.decodeIfPresent([URL].self, forKey: .folders)?.first
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(publications, forKey: .copies)
        try container.encodeIfPresent(location, forKey: .location)
    }

    /// A recording's shared copies, the sync location's first.
    public func copies(of source: URL) -> [MeetingPublication] {
        (publications[source.standardizedFileURL] ?? []).sorted { a, b in (a.folder == location ? 0 : 1) < (b.folder == location ? 0 : 1) }
    }

    fileprivate mutating func change(_ source: URL, _ id: UUID, _ edit: (inout MeetingPublication) -> Void) {
        guard let index = publications[source]?.firstIndex(where: { $0.id == id }) else { return }
        edit(&publications[source]![index])
    }

    fileprivate mutating func drop(_ source: URL, _ id: UUID) {
        publications[source]?.removeAll { $0.id == id }
        if publications[source]?.isEmpty == true { publications[source] = nil }
    }
}

public struct MeetingSyncSnapshot: Equatable, Sendable {
    public let state: MeetingSyncState
    public let meetings: [SharedLibraryItem]
    public let failures: [URL: String]
    /// Recordings whose shared copy is being made right now.
    public let preparing: Set<URL>
    /// Meetings seen in a team folder whose notes are still on their way to this Mac.
    public let arriving: Int
}

public actor MeetingSync {
    private let stateFile: URL
    private var state = MeetingSyncState()
    private var loaded = false
    private var cache: [URL: (String, SharedMeeting)] = [:]
    /// The signature each copy was last published from, by its id.
    private var published: [UUID: String] = [:]
    /// Making a shared copy renders and copies files, off the actor, so the state it reports
    /// is read while it works. One at a time for each recording.
    private var running: [URL: Task<Void, Error>] = [:]
    private var preparing: Set<URL> = []
    /// By recording, and by each copy's folder in the team folder.
    private var publishFailures: [URL: String] = [:]
    private var copyFailures: [URL: String] = [:]
    private let fm = FileManager.default

    public init(stateFile: URL) { self.stateFile = stateFile }

    private func load() throws {
        guard !loaded else { return }
        if fm.fileExists(atPath: stateFile.path) {
            state = try JSONDecoder().decode(MeetingSyncState.self, from: Data(contentsOf: stateFile))
        }
        loaded = true
    }

    private func save(_ next: MeetingSyncState) throws {
        try fm.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: stateFile, options: .atomic)
        state = next
    }

    /// Stops using the sync location: nothing new is offered a sync there and colleagues'
    /// meetings are no longer listed. Recordings already synced there stay synced, and
    /// nothing in the folder changes.
    public func disconnect() throws {
        try load()
        var next = state
        next.location = nil
        if next != state { try save(next) }
    }

    /// The ids of the copies the owner synced this recording to, one a line, kept in the
    /// recording so they follow it when the library moves.
    private func consent(_ source: URL) -> Set<UUID> {
        let text = (try? String(contentsOf: RecordingLayout(directory: source).readURL("sync-id"), encoding: .utf8)) ?? ""
        return Set(text.split(whereSeparator: \.isNewline).compactMap { UUID(uuidString: String($0)) })
    }

    private func addConsent(_ id: UUID, to source: URL) throws {
        let ids = (consent(source).map(\.uuidString).sorted() + [id.uuidString]).joined(separator: "\n")
        try ids.write(to: RecordingLayout(directory: source).writeURL("sync-id"), atomically: true, encoding: .utf8)
    }

    public func relocate(to directories: [URL]) throws {
        try load()
        var next = state
        for directory in directories {
            let target = RecordingLayout(directory: directory).directory
            let ids = consent(target)
            guard !ids.isEmpty,
                  let old = state.publications.first(where: { $0.value.contains { ids.contains($0.id) } }),
                  old.key != target, !fm.fileExists(atPath: old.key.path) else { continue }
            next.publications[old.key] = nil
            next.publications[target] = old.value
        }
        if next != state { try save(next) }
    }

    public func sync(_ source: URL, to destination: URL) async throws {
        try load()
        let source = source.standardizedFileURL
        let folder = try checkedFolder(destination)
        let root = source.deletingLastPathComponent().pathComponents
        guard !folder.pathComponents.starts(with: root), !root.starts(with: folder.pathComponents),
              !RecordingLibrary.isRecording(folder) else {
            throw RecordingShare.Failure.failed("Choose a team folder outside the recording library.")
        }
        /// Another folder is another copy; the same folder brings its copy up to date.
        if let existing = state.publications[source]?.first(where: { $0.folder == folder }) {
            guard !existing.withdrawing else { throw RecordingShare.Failure.failed("Finish removing it from there first.") }
            guard consent(source).contains(existing.id) else { throw CocoaError(.fileWriteNoPermission) }
            published[existing.id] = nil
        } else {
            let publication = MeetingPublication(source: source, folder: folder)
            try addConsent(publication.id, to: source)
            var next = state
            next.publications[source, default: []].append(publication)
            if next.location == nil { next.location = folder }
            try save(next)
        }
        try await reconcile(source)
    }

    /// Chooses the sync location. The first recording synced while there is none chooses it
    /// too; syncing or moving one recording to another folder leaves it as it is.
    public func setLocation(_ destination: URL) throws {
        try load()
        let folder = try checkedFolder(destination)
        guard !RecordingLibrary.isRecording(folder) else {
            throw RecordingShare.Failure.failed("Choose a team folder outside the recording library.")
        }
        var next = state
        next.location = folder
        if next != state { try save(next) }
    }

    /// Stops syncing a recording: every copy, or only the one in `folder`.
    public func remove(_ source: URL, from folder: URL? = nil) async throws {
        try load()
        let source = source.standardizedFileURL
        guard let copies = state.publications[source] else { return }
        var next = state
        for copy in copies where folder == nil || copy.folder == folder { next.change(source, copy.id) { $0.withdrawing = true } }
        guard next != state else { return }
        try save(next)
        try await reconcile(source)
    }

    /// Lets go of a recording's shared copies without touching them, for an original that is
    /// being deleted while colleagues keep its copies. They are nobody's to update or put back
    /// from then on, and the one in the sync location is listed as shared, like anyone else's.
    public func forget(_ source: URL) throws {
        try load()
        let source = source.standardizedFileURL
        guard let copies = state.publications[source] else { return }
        var next = state
        next.publications[source] = nil
        try save(next)
        for copy in copies {
            published[copy.id] = nil
            copyFailures[copy.directory] = nil
        }
        publishFailures[source] = nil
    }

    private func checkedFolder(_ url: URL) throws -> URL {
        let folder = URL(fileURLWithPath: url.path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              !fm.fileExists(atPath: folder.appendingPathComponent(SharedMeeting.manifest).path)
        else { throw CocoaError(.fileReadUnsupportedScheme) }
        return folder
    }

    /// Brings every shared copy up to date, then says where things stand.
    public func refresh() async throws -> MeetingSyncSnapshot {
        await reconcileAll()
        return try snapshot()
    }

    public func reconcileAll() async {
        guard (try? load()) != nil else { return }
        for source in Array(state.publications.keys) { try? await reconcile(source) }
        publishFailures = publishFailures.filter { state.publications[$0.key] != nil }
        let directories = Set(state.publications.values.joined().map(\.directory))
        copyFailures = copyFailures.filter { directories.contains($0.key) }
    }

    /// Where things stand, without making or changing any shared copy.
    public func snapshot() throws -> MeetingSyncSnapshot {
        try load()
        var failures = publishFailures.merging(copyFailures) { first, _ in first }
        var arriving = 0
        let copies = state.publications.values.joined()
        let own = Set(copies.map(\.directory))
        /// By id as well: the same folder can be reached by two paths.
        let ownIDs = Set(copies.map(\.id.uuidString))
        var items = [SharedLibraryItem]()
        if let folder = state.location {
            do {
                let children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                let candidates = children.filter { UUID(uuidString: String($0.lastPathComponent.suffix(36))) != nil }
                let existing = Set(candidates.map { folder.appendingPathComponent($0.lastPathComponent, isDirectory: true) })
                for directory in existing.subtracting(own) where !ownIDs.contains(String(directory.lastPathComponent.suffix(36))) {
                    do {
                        if let found = try item(directory) { items.append(found) } else { arriving += 1 }
                    } catch { failures[directory] = error.localizedDescription }
                }
            } catch {
                failures[folder] = RecordingShare.Failure.folderUnavailable(folder.lastPathComponent).localizedDescription
            }
        }
        let visible = Set(items.map(\.id))
        cache = cache.filter { visible.contains($0.key) }
        return MeetingSyncSnapshot(state: state, meetings: items.sorted { $0.meeting.started > $1.meeting.started },
                                   failures: failures, preparing: preparing, arriving: arriving)
    }

    /// Nil while the meeting's notes have not arrived: still uploading from its owner's Mac,
    /// or on their way down.
    private func item(_ directory: URL) throws -> SharedLibraryItem? {
        try SharedFiles.check(directory)
        let file = directory.appendingPathComponent(SharedMeeting.manifest)
        if CloudFile.download(file) == .missing { return nil }
        if try SharedFiles.requestDownload(file) {
            /// A newer version on its way: the one already read goes on being shown.
            return cache[directory].map { SharedLibraryItem(directory: directory, meeting: $0.1) }
        }
        let stamp = try SharedMeeting.stamp(file)
        if let (previous, meeting) = cache[directory], previous == stamp { return SharedLibraryItem(directory: directory, meeting: meeting) }
        let meeting = try SharedMeeting.read(directory)
        guard directory.lastPathComponent.hasSuffix(meeting.id.uuidString) else { throw CocoaError(.fileReadCorruptFile) }
        cache[directory] = (stamp, meeting)
        return SharedLibraryItem(directory: directory, meeting: meeting)
    }

    private func reconcile(_ source: URL) async throws {
        while let task = running[source] {
            _ = await task.result
            if running[source] == task { running[source] = nil }
        }
        let task = Task { try await self.reconcileOnce(source) }
        running[source] = task
        let result = await task.result
        if running[source] == task { running[source] = nil }
        switch result {
        case .success: publishFailures[source] = nil
        case .failure(let error):
            publishFailures[source] = error.localizedDescription
            throw error
        }
    }

    /// Each copy in turn; one that fails does not hold up the others, and the first failure
    /// is the recording's.
    private func reconcileOnce(_ source: URL) async throws {
        var signature: Result<String, Error>?
        var first: Error?
        for copy in state.publications[source] ?? [] {
            do {
                try await reconcile(copy, of: source) {
                    if signature == nil {
                        signature = await Task.detached(priority: .utility) { Result { try Self.signature(of: source) } }.value
                    }
                    return try signature!.get()
                }
                copyFailures[copy.directory] = nil
            } catch {
                copyFailures[copy.directory] = error.localizedDescription
                first = first ?? error
            }
        }
        if let first { throw first }
    }

    private func reconcile(_ publication: MeetingPublication, of source: URL, signature: () async throws -> String) async throws {
        let current = { [self] in state.publications[source]?.first { $0.id == publication.id } }
        if publication.withdrawing {
            try await Task.detached(priority: .utility) { try publication.withdraw(from: publication.folder) }.value
        } else {
            guard consent(source).contains(publication.id) else { throw CocoaError(.fileReadNoPermission) }
            let signature = try await signature()
            let present = fm.fileExists(atPath: publication.directory.path)
            let tampered = await Task.detached(priority: .utility) { publication.isTampered }.value
            if published[publication.id] != signature || !present || tampered {
                preparing.insert(source)
                defer { preparing.remove(source) }
                let fingerprints = try await Task.detached(priority: .utility) { try publication.publish(from: source) }.value
                /// Removed while its copy was being made: the next pass does the rest.
                guard let now = current(), now.folder == publication.folder, !now.withdrawing else { return }
                published[publication.id] = signature
                var next = state
                next.change(source, publication.id) {
                    $0.fingerprints = fingerprints
                    if tampered { $0.restored = Date() }
                }
                if next != state { try save(next) }
            }
        }
        /// A move begun by a version that still had Move to…, finished.
        if let old = publication.previousFolder {
            try await Task.detached(priority: .utility) { try publication.withdraw(from: old) }.value
        }
        guard let now = current(), now.folder == publication.folder, now.withdrawing == publication.withdrawing else { return }
        if publication.withdrawing || publication.previousFolder != nil {
            var next = state
            if publication.withdrawing { next.drop(source, publication.id); published[publication.id] = nil }
            else { next.change(source, publication.id) { $0.previousFolder = nil } }
            try save(next)
        }
    }

    /// Everything a shared copy is made from, so it is made again only when some of it changed.
    private static func signature(of source: URL) throws -> String {
        guard let media = RecordingMedia.merged(in: source) else { throw RecordingShare.Failure.nothingToShare }
        let layout = RecordingLayout(directory: source)
        let plan = OutputPlan(directory: source)
        let files = TranscriptStore.layerFiles(in: source) + [media, layout.recordingInfo]
            + [TranscriptStore.activeSummary(in: source)].compactMap { $0 }
            + [plan.systemAudio, plan.microphone, plan.microphoneLive]
            + [MixDecision.fileName, Thumbnail.fileName].map(layout.readURL)
        return files.map { $0.lastPathComponent + ((try? SharedMeeting.stamp($0)) ?? "") }.joined(separator: "|")
    }
}
