import AnyRecKit
import AppKit
import Observation

@MainActor @Observable
final class TeamLibrary {
    private let store: MeetingSync
    private(set) var snapshot: MeetingSyncSnapshot?
    private(set) var busy = false
    var error: String?
    private var timer: Task<Void, Never>?

    init(stateFile: URL = URL.applicationSupportDirectory.appending(path: "anyrec/team-folders.json")) {
        store = MeetingSync(stateFile: stateFile)
    }

    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func refresh() async {
        do {
            let next = try await store.refresh()
            if snapshot != next { snapshot = next }
        } catch { self.error = error.localizedDescription }
    }

    func publication(_ entry: LibraryEntry) -> MeetingPublication? {
        snapshot?.state.publications[entry.directory.standardizedFileURL]
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

    func publish(_ entry: LibraryEntry, to destination: URL? = nil) {
        guard let folder = destination ?? choose("Choose sync destination", message: Wording.viewOnlyTip) else { return }
        let old = publication(entry)
        run {
            if let old, old.folder.standardizedFileURL != folder.standardizedFileURL {
                try DraftRecordingLink.save(nil, at: RecordingCloud.linkFile(for: entry))
            }
            try await self.store.sync(entry.directory, to: folder)
        }
    }

    func relocate(_ directories: [URL]) async {
        do { try await store.relocate(to: directories) } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func remove(_ entry: LibraryEntry, then completion: @escaping () -> Void = {}) {
        run {
            try DraftRecordingLink.save(nil, at: RecordingCloud.linkFile(for: entry))
            try await self.store.remove(entry.directory)
            completion()
        }
    }

    func add(_ item: SharedLibraryItem) {
        run { try await self.store.addToLibrary(item.directory) }
    }

    func copy(_ item: SharedLibraryItem, controller: RecordingController) {
        let library = controller.recordingsFolder
        run {
            _ = try await item.meeting.playableFile(in: item.directory)
            let new = try await Task.detached {
                try item.meeting.makeCopy(from: item.directory, in: library)
            }.value
            await controller.reloadLibrary()
            controller.selection = RecordingLayout(directory: new).directory
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
            await refresh()
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
