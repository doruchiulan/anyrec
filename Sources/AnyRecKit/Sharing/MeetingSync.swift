import Foundation

public struct SharedLibraryItem: Equatable, Sendable, Identifiable {
    public let directory: URL
    public let meeting: SharedMeeting
    public var id: URL { directory }
}

public struct MeetingSyncState: Codable, Equatable, Sendable {
    public fileprivate(set) var publications: [URL: MeetingPublication] = [:]
    public fileprivate(set) var folders: [URL] = []
    public fileprivate(set) var linked: Set<URL> = []
    public fileprivate(set) var lastFolder: URL?
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
    private var published: [URL: String] = [:]
    /// Making a shared copy renders and copies files, off the actor, so the state it reports
    /// is read while it works. One at a time for each recording.
    private var running: [URL: Task<Void, Error>] = [:]
    private var preparing: Set<URL> = []
    private var publishFailures: [URL: String] = [:]
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

    public func connect(_ folder: URL) throws {
        try load()
        let folder = try checkedFolder(folder)
        guard !state.folders.contains(folder) else { return }
        var next = state
        next.folders.append(folder)
        try save(next)
    }

    public func addToLibrary(_ directory: URL) throws {
        try load()
        guard state.folders.contains(directory.deletingLastPathComponent()), try SharedMeeting.read(directory).id ==
            UUID(uuidString: String(directory.lastPathComponent.suffix(36))) else { throw RecordingShare.Failure.failed("Choose a meeting in a connected team folder.") }
        var next = state
        next.linked.insert(directory)
        try save(next)
    }

    public func removeFromLibrary(_ directory: URL) throws {
        try load()
        var next = state
        next.linked.remove(directory)
        if next != state { try save(next) }
    }

    /// Stops listing a team folder here. Nothing in it changes.
    public func disconnect(_ folder: URL) throws {
        try load()
        var next = state
        next.folders.removeAll { $0 == folder }
        next.linked = next.linked.filter { $0.deletingLastPathComponent() != folder }
        if next != state { try save(next) }
    }

    private func consentFile(_ source: URL) -> URL { RecordingLayout(directory: source).url("sync-id") }

    private func consent(_ source: URL) -> UUID? {
        (try? String(contentsOf: consentFile(source), encoding: .utf8)).flatMap(UUID.init(uuidString:))
    }

    public func relocate(to directories: [URL]) throws {
        try load()
        var next = state
        for directory in directories {
            let target = RecordingLayout(directory: directory).directory
            guard let id = consent(target),
                  let old = state.publications.first(where: { $0.value.id == id }),
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
        let existing = state.publications[source]
        guard existing?.withdrawing != true, existing?.previousFolder == nil else {
            throw RecordingShare.Failure.failed("Finish the pending move or removal first.")
        }
        var next = state
        if let existing {
            guard consent(source) == existing.id else { throw CocoaError(.fileWriteNoPermission) }
            next.publications[source] = existing.folder == folder ? existing : existing.moved(to: folder)
        } else {
            let publication = MeetingPublication(source: source, folder: folder)
            try publication.id.uuidString.write(to: RecordingLayout(directory: source).writeURL("sync-id"), atomically: true, encoding: .utf8)
            next.publications[source] = publication
        }
        next.lastFolder = folder
        try save(next)
        published[source] = nil
        try await reconcile(source)
    }

    /// Where "Sync to …" sends a recording until another folder is chosen. Every sync and
    /// move sets it too.
    public func setDefaultFolder(_ destination: URL) throws {
        try load()
        let folder = try checkedFolder(destination)
        guard !RecordingLibrary.isRecording(folder) else {
            throw RecordingShare.Failure.failed("Choose a team folder outside the recording library.")
        }
        var next = state
        next.lastFolder = folder
        if next != state { try save(next) }
    }

    public func remove(_ source: URL) async throws {
        try load()
        let source = source.standardizedFileURL
        guard state.publications[source] != nil else { return }
        var next = state
        next.publications[source]?.withdrawing = true
        try save(next)
        try await reconcile(source)
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
    }

    /// Where things stand, without making or changing any shared copy.
    public func snapshot() throws -> MeetingSyncSnapshot {
        try load()
        var failures = publishFailures
        var arriving = 0
        let own = Set(state.publications.values.map(\.directory))
        /// By id as well: the same folder can be reached by two paths.
        let ownIDs = Set(state.publications.values.map(\.id.uuidString))
        var items = [SharedLibraryItem]()
        var next = state
        for folder in state.folders {
            do {
                let children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                let candidates = children.filter { UUID(uuidString: String($0.lastPathComponent.suffix(36))) != nil }
                let existing = Set(candidates.map { folder.appendingPathComponent($0.lastPathComponent, isDirectory: true) })
                next.linked = next.linked.filter { $0.deletingLastPathComponent() != folder || existing.contains($0) }
                for directory in existing.subtracting(own) where !ownIDs.contains(String(directory.lastPathComponent.suffix(36))) {
                    do {
                        if let found = try item(directory) { items.append(found) } else { arriving += 1 }
                    } catch { failures[directory] = error.localizedDescription }
                }
            } catch {
                failures[folder] = RecordingShare.Failure.folderUnavailable(folder.lastPathComponent).localizedDescription
            }
        }
        if next != state { try save(next) }
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

    private func reconcileOnce(_ source: URL) async throws {
        guard let publication = state.publications[source] else { return }
        if publication.withdrawing {
            try await Task.detached(priority: .utility) { try publication.withdraw(from: publication.folder) }.value
        } else {
            guard consent(source) == publication.id else { throw CocoaError(.fileReadNoPermission) }
            let signature = try await Task.detached(priority: .utility) { try Self.signature(of: source) }.value
            let present = fm.fileExists(atPath: publication.directory.path)
            let tampered = await Task.detached(priority: .utility) { publication.isTampered }.value
            if published[source] != signature || !present || tampered {
                preparing.insert(source)
                defer { preparing.remove(source) }
                let fingerprints = try await Task.detached(priority: .utility) { try publication.publish(from: source) }.value
                /// Moved or removed while its copy was being made: what is recorded is for
                /// the publication it was made for, and the next pass does the rest.
                guard let now = state.publications[source], now.id == publication.id, now.folder == publication.folder else { return }
                published[source] = signature
                var next = state
                next.publications[source]?.fingerprints = fingerprints
                if tampered { next.publications[source]?.restored = Date() }
                if next != state { try save(next) }
            }
        }
        if let old = publication.previousFolder {
            try await Task.detached(priority: .utility) { try publication.withdraw(from: old) }.value
        }
        guard let now = state.publications[source], now.id == publication.id,
              now.folder == publication.folder, now.withdrawing == publication.withdrawing else { return }
        if publication.withdrawing || publication.previousFolder != nil {
            var next = state
            if publication.withdrawing { next.publications[source] = nil; published[source] = nil }
            else { next.publications[source]?.previousFolder = nil }
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
