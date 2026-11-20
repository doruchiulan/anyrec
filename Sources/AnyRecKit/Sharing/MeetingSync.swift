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
}

public actor MeetingSync {
    private let stateFile: URL
    private var state = MeetingSyncState()
    private var loaded = false
    private var cache: [URL: (String, SharedMeeting)] = [:]
    private var published: [URL: String] = [:]
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

    public func sync(_ source: URL, to destination: URL) throws {
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
        try reconcile(source)
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

    public func remove(_ source: URL) throws {
        try load()
        let source = source.standardizedFileURL
        guard state.publications[source] != nil else { return }
        var next = state
        next.publications[source]?.withdrawing = true
        try save(next)
        try reconcile(source)
    }

    private func checkedFolder(_ url: URL) throws -> URL {
        let folder = URL(fileURLWithPath: url.path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              !fm.fileExists(atPath: folder.appendingPathComponent(SharedMeeting.manifest).path)
        else { throw CocoaError(.fileReadUnsupportedScheme) }
        return folder
    }

    public func refresh() throws -> MeetingSyncSnapshot {
        try load()
        var failures: [URL: String] = [:]
        for source in Array(state.publications.keys) {
            do { try reconcile(source) } catch { failures[source] = error.localizedDescription }
        }
        let own = Set(state.publications.values.map(\.directory))
        var items = [SharedLibraryItem]()
        var next = state
        for folder in state.folders {
            do {
                let children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                let candidates = children.filter { UUID(uuidString: String($0.lastPathComponent.suffix(36))) != nil }
                let existing = Set(candidates.map { folder.appendingPathComponent($0.lastPathComponent, isDirectory: true) })
                next.linked = next.linked.filter { $0.deletingLastPathComponent() != folder || existing.contains($0) }
                for directory in existing.subtracting(own) {
                    do { items.append(try item(directory)) } catch { failures[directory] = error.localizedDescription }
                }
            } catch { failures[folder] = error.localizedDescription }
        }
        if next != state { try save(next) }
        let visible = Set(items.map(\.id))
        cache = cache.filter { visible.contains($0.key) }
        return MeetingSyncSnapshot(state: state, meetings: items.sorted { $0.meeting.started > $1.meeting.started }, failures: failures)
    }

    private func item(_ directory: URL) throws -> SharedLibraryItem {
        try SharedFiles.check(directory)
        let file = directory.appendingPathComponent(SharedMeeting.manifest)
        if try SharedFiles.requestDownload(file) { throw RecordingShare.Failure.failed("Downloading the meeting notes…") }
        let stamp = try SharedMeeting.stamp(file)
        if let (previous, meeting) = cache[directory], previous == stamp { return SharedLibraryItem(directory: directory, meeting: meeting) }
        let meeting = try SharedMeeting.read(directory)
        guard directory.lastPathComponent.hasSuffix(meeting.id.uuidString) else { throw CocoaError(.fileReadCorruptFile) }
        cache[directory] = (stamp, meeting)
        return SharedLibraryItem(directory: directory, meeting: meeting)
    }

    private func reconcile(_ source: URL) throws {
        guard let publication = state.publications[source] else { return }
        if publication.withdrawing {
            try publication.withdraw(from: publication.folder)
        } else {
            guard consent(source) == publication.id else { throw CocoaError(.fileReadNoPermission) }
            guard let media = RecordingMedia.merged(in: source) else { throw RecordingShare.Failure.nothingToShare }
            let files = TranscriptStore.layerFiles(in: source) + [media, RecordingLayout(directory: source).recordingInfo]
                + [TranscriptStore.activeSummary(in: source)].compactMap { $0 }
            let signature = files.map { $0.lastPathComponent + ((try? SharedMeeting.stamp($0)) ?? "") }.joined(separator: "|")
            let mediaName = RecordingInfo.read(source)?.audioOnly == true ? "Recording.m4a" : "Recording.mp4"
            let present = fm.fileExists(atPath: publication.directory.path)
            /// Something in the shared folder is not what AnyRec wrote: changed, deleted,
            /// or the whole meeting gone. Put back from the owner's recording, and say so.
            let tampered = publication.fingerprints.map { recorded in
                !present || publication.fingerprints(mediaName: mediaName) != recorded
            } ?? false
            if published[source] != signature || !present || tampered {
                try publication.publish(from: source)
                published[source] = signature
                var next = state
                next.publications[source]?.fingerprints = publication.fingerprints(mediaName: mediaName)
                if tampered { next.publications[source]?.restored = Date() }
                if next != state { try save(next) }
            }
        }
        if let old = publication.previousFolder { try publication.withdraw(from: old) }
        if publication.withdrawing || publication.previousFolder != nil {
            var next = state
            if publication.withdrawing { next.publications[source] = nil; published[source] = nil }
            else { next.publications[source]?.previousFolder = nil }
            try save(next)
        }
    }
}
