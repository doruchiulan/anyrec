import AnyRecKit
import AppKit
import Observation

/// Synced recordings and the team folders' meetings, as the window shows them: what
/// `MeetingSync` reports, and how far each file has got with its cloud provider. The one
/// place that polls either; rows, the header and the sync button read what it holds.
@MainActor @Observable
final class TeamLibrary {
    private let store: MeetingSync
    private(set) var snapshot: MeetingSyncSnapshot?
    private(set) var busy = false
    /// Meetings being copied into the library, which waits for their recordings to arrive.
    private(set) var copying: Set<URL> = []
    /// The owner's recordings being synced, moved or withdrawn because they were just asked to.
    private(set) var syncing: Set<URL> = []
    private(set) var uploads: [URL: SharedUpload] = [:]
    /// Whether each listed meeting's recording is on this Mac, in the cloud, or not up yet.
    private(set) var arrivals: [URL: CloudFile.Download] = [:]
    /// What each recording's row and header show, held so a list redraws when a mark
    /// changes and not with every second of an upload.
    private(set) var marks: [URL: CloudMark] = [:]
    /// The listed meetings as the library lists its own recordings, newest first.
    private(set) var entries: [LibraryEntry] = []
    var error: String?
    private var timers: [Task<Void, Never>] = []
    private let progress = CloudProgress()

    init(stateFile: URL = URL.applicationSupportDirectory.appending(path: "anyrec/team-folders.json")) {
        store = MeetingSync(stateFile: stateFile)
    }

    func start() {
        guard timers.isEmpty else { return }
        timers = [
            Task { [weak self] in
                while !Task.isCancelled {
                    guard let store = self?.store else { return }
                    await store.reconcileAll()
                    try? await Task.sleep(for: .seconds(10))
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    await self?.look()
                    guard let self else { return }
                    /// Quick while something is moving, so its progress is worth watching.
                    try? await Task.sleep(for: .seconds(self.isMoving ? 1.5 : 8))
                }
            },
        ]
    }

    private var isMoving: Bool {
        snapshot?.preparing.isEmpty == false || (snapshot?.arriving ?? 0) > 0 || !syncing.isEmpty
            || uploads.values.contains { if case .uploading = $0 { true } else { false } }
            || arrivals.values.contains { $0 == .downloading }
    }

    /// Where everything stands now. Assigned only where it changed: every assignment
    /// redraws what reads it.
    private func look() async {
        do {
            let next = try await store.snapshot()
            if snapshot != next {
                if snapshot?.meetings != next.meetings {
                    entries = next.meetings.map { $0.meeting.entry(in: $0.directory) }
                }
                snapshot = next
            }
        } catch {
            if self.error == nil { self.error = error.localizedDescription }
            return
        }
        let publications = snapshot?.state.publications ?? [:]
        let fractions = progress.fractions
        let media = entries.compactMap { entry in entry.shared.map { (entry.directory, $0.media) } }
        let (up, down) = await Task.detached(priority: .utility) {
            (publications.compactMapValues { $0.uploadStatus(fractions: fractions) },
             Dictionary(media.map { ($0.0, CloudFile.download($0.1)) }, uniquingKeysWith: { first, _ in first }))
        }.value
        if uploads != up { uploads = up }
        if arrivals != down { arrivals = down }
        var marks = [URL: CloudMark]()
        for source in Set(publications.keys).union(syncing) { marks[source] = ownMark(source) }
        for entry in entries { marks[entry.directory] = sharedMark(entry.directory) }
        if self.marks != marks { self.marks = marks }
        progress.follow(publications.flatMap { source, publication -> [URL] in
            if case .uploading? = up[source] { publication.files } else { [] }
        })
    }

    func publication(_ entry: LibraryEntry) -> MeetingPublication? {
        snapshot?.state.publications[entry.directory.standardizedFileURL]
    }

    func upload(_ entry: LibraryEntry) -> SharedUpload? { uploads[entry.directory.standardizedFileURL] }

    func failure(_ entry: LibraryEntry) -> String? { snapshot?.failures[entry.directory.standardizedFileURL] }

    /// What its header says while its shared copy is being made or is going up.
    func note(_ entry: LibraryEntry) -> String? {
        if isPreparing(entry) { return "Preparing the shared copy…" }
        if case .uploading(let done, let total)? = upload(entry) { return Wording.uploading(done: done, total: total) }
        return nil
    }

    /// Its shared copy is being made, or is about to be.
    func isPreparing(_ entry: LibraryEntry) -> Bool {
        let source = entry.directory.standardizedFileURL
        return syncing.contains(source) || snapshot?.preparing.contains(source) == true
    }

    func meeting(_ directory: URL) -> SharedMeeting? { snapshot?.meetings.first { $0.directory == directory }?.meeting }

    func isLinked(_ directory: URL) -> Bool { snapshot?.state.linked.contains(directory) == true }

    /// The cloud mark on a recording's row and header, its own or a shared one.
    func mark(_ entry: LibraryEntry) -> CloudMark? {
        marks[entry.shared == nil ? entry.directory.standardizedFileURL : entry.directory]
    }

    private func sharedMark(_ directory: URL) -> CloudMark? {
        switch arrivals[directory] {
        case .remote, .failed: .remote
        case .downloading: .downloading
        case .missing: .waiting
        case .local, nil: nil
        }
    }

    private func ownMark(_ source: URL) -> CloudMark? {
        if snapshot?.failures[source] != nil { return .failed }
        if syncing.contains(source) || snapshot?.preparing.contains(source) == true { return .uploading }
        switch uploads[source] {
        case .uploaded: return .uploaded
        case .uploading: return .uploading
        case .failed: return .failed
        case .notCloud, nil: return nil
        }
    }

    /// Settings' Change… for the sync folder: where "Sync to …" sends recordings.
    func chooseDefaultFolder() {
        guard let folder = choose("Use for syncing", message: Wording.viewOnlyTip) else { return }
        run { try await self.store.setDefaultFolder(folder) }
    }

    func connect() {
        guard let folder = choose("Connect team folder") else { return }
        run { try await self.store.connect(folder) }
    }

    func disconnect(_ folder: URL) { run { try await self.store.disconnect(folder) } }

    func publish(_ entry: LibraryEntry, to destination: URL? = nil) {
        guard let folder = destination ?? choose("Choose sync destination", message: Wording.viewOnlyTip) else { return }
        let old = publication(entry)
        follow(entry) {
            if let old, old.folder.standardizedFileURL != folder.standardizedFileURL {
                try DraftRecordingLink.save(nil, at: RecordingCloud.linkFile(for: entry))
            }
            try await self.store.sync(entry.directory, to: folder)
        }
    }

    func retry(_ entry: LibraryEntry) {
        guard let folder = publication(entry)?.folder else { return }
        follow(entry) { try await self.store.sync(entry.directory, to: folder) }
    }

    func relocate(_ directories: [URL]) async {
        do { try await store.relocate(to: directories) } catch { self.error = error.localizedDescription }
        await look()
    }

    func remove(_ entry: LibraryEntry, then completion: @escaping () -> Void = {}) {
        follow(entry) {
            try DraftRecordingLink.save(nil, at: RecordingCloud.linkFile(for: entry))
            try await self.store.remove(entry.directory)
            completion()
        }
    }

    func add(_ directory: URL) { run { try await self.store.addToLibrary(directory) } }

    func removeFromLibrary(_ directory: URL) { run { try await self.store.removeFromLibrary(directory) } }

    /// Waits for the recording and its tracks to arrive, however long that takes, with the
    /// rest of the window usable meanwhile.
    func copy(_ entry: LibraryEntry, controller: RecordingController) {
        guard let meeting = meeting(entry.directory), copying.insert(entry.directory).inserted else { return }
        let library = controller.recordingsFolder, directory = entry.directory
        Task {
            defer { copying.remove(directory) }
            do {
                try await meeting.localFiles(in: directory)
                let new = try await Task.detached { try meeting.makeCopy(from: directory, in: library) }.value
                await controller.reloadLibrary()
                if controller.selection == directory { controller.selection = RecordingLayout(directory: new).directory }
            } catch { self.error = error.localizedDescription }
        }
    }

    /// One recording's sync, on its own: preparing a long call takes a while, and the other
    /// recordings' buttons have no reason to wait for it.
    private func follow(_ entry: LibraryEntry, _ action: @escaping @MainActor () async throws -> Void) {
        let source = entry.directory.standardizedFileURL
        guard syncing.insert(source).inserted else { return }
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            await look()
            syncing.remove(source)
        }
        Task { await look() }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
            await look()
        }
    }

    func choose(_ prompt: String, message: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.prompt = prompt
        if let message { panel.message = message }
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = snapshot?.state.lastFolder
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// One mark for where a recording is, the same on its row and its header.
enum CloudMark: Equatable {
    /// The owner's: the shared copy is going up, is up, or could not be made or uploaded.
    case uploading, uploaded, failed
    /// Someone else's: in the cloud, on its way here, or not uploaded by its owner yet.
    case remote, downloading, waiting

    var symbol: String {
        switch self {
        case .uploading: "arrow.up.circle.fill"
        case .uploaded: "icloud.fill"
        case .failed: "exclamationmark.icloud.fill"
        case .remote: "icloud.and.arrow.down"
        case .downloading: "arrow.down.circle.fill"
        case .waiting: "clock.fill"
        }
    }

    var label: String {
        switch self {
        case .uploading: "Uploading the shared copy"
        case .uploaded: "Recording available in the cloud"
        case .failed: "Sync needs attention"
        case .remote: "In the cloud, downloads when you play it"
        case .downloading: "Downloading"
        case .waiting: "Not uploaded by its owner yet"
        }
    }
}
