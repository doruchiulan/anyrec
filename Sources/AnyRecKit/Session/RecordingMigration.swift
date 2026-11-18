import Foundation

/// Moves recordings into the current layout and the current root. Pure file moves: nothing
/// is deleted (except an old root that holds nothing but `.DS_Store`), no destination is
/// ever overwritten, and every step can be run again — a folder half moved is finished by
/// the next run, a finished one is left alone. The Kit's readers fall back to the flat
/// layout, so a folder this has not reached still reads; the MCP server never calls it.
public enum RecordingMigration {
    public struct Report: Sendable, Equatable {
        /// Folders changed (files moved, renamed or given an id), at their final paths.
        public var migrated: [URL] = []
        /// Folders moved to another root, at their new paths.
        public var moved: [URL] = []
        /// Folders left alone because something is working on them.
        public var skipped: [URL] = []
        public var failures: [String] = []
        public init() {}
        public var changedAnything: Bool { !migrated.isEmpty || !moved.isEmpty }
    }

    public enum MoveError: LocalizedError, Equatable {
        case sameFolder
        case insideCurrent
        case containsCurrent
        case notWritable(String)

        public var errorDescription: String? {
            switch self {
            case .sameFolder: "That is the folder recordings are already in."
            case .insideCurrent: "Choose a folder outside the current recordings folder."
            case .containsCurrent: "Choose a folder that does not contain the current recordings folder."
            case .notWritable(let path): "AnyRec cannot write to \(path)."
            }
        }
    }

    // MARK: One folder

    /// Brings one recording folder into the layout and gives it its readable name. Returns
    /// the folder's path afterwards (the same when it was not renamed). Never throws for a
    /// file that cannot be moved: that file stays where it is and is read from there.
    @discardableResult
    public static func migrate(folder: URL) -> URL {
        let layout = RecordingLayout(directory: folder)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: layout.directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return folder }

        // 1. The files that belong in a subfolder.
        let flat = (try? fm.contentsOfDirectory(at: layout.directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let movable = flat.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
                && RecordingLayout.place(of: $0.lastPathComponent) != .top
        }
        if !movable.isEmpty {
            try? layout.prepare(RecordingLayout.Place.allCases.filter { $0 != .top })
        }
        for file in movable {
            let destination = layout.url(file.lastPathComponent)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try? fm.moveItem(at: file, to: destination)
        }

        // 2. recording.json learns its id and start from the old name.
        let name = layout.directory.lastPathComponent
        if var info = RecordingInfo.read(layout.directory) {
            var edited = false
            if info.id == nil, name.hasPrefix("rec-") { info.id = name; edited = true }
            if info.startedAt == nil, let date = OutputPlan.date(fromFolderName: name) { info.startedAt = date; edited = true }
            if edited { try? info.write(to: layout.directory) }
        }

        // 3. The renderings of what is current.
        TranscriptStore.renderMissing(in: layout.directory)

        // 4. The readable name, last: an interrupted run is finished by the next.
        var final = layout.directory
        if name.hasPrefix("rec-"), let info = RecordingInfo.read(layout.directory) {
            let started = info.startedAt ?? OutputPlan.date(fromFolderName: name) ?? RecordingLibrary.started(layout.directory)
            let wanted = RecordingMedia.folderName(
                title: info.title, app: RecordingMedia.appName(for: info), started: started)
            let root = layout.directory.deletingLastPathComponent()
            let unique = RecordingLayout.uniqueName(wanted, in: root, excluding: layout.directory)
            let target = root.appendingPathComponent(unique)
            if target.standardizedFileURL != layout.directory, !fm.fileExists(atPath: target.path),
               (try? fm.moveItem(at: layout.directory, to: target)) != nil {
                final = RecordingLayout(directory: target).directory
            }
        }
        return final
    }

    /// Every recording folder directly under `root`, each migrated unless `isBusy` says
    /// something is recording or processing it.
    public static func migrateAll(in root: URL, isBusy: (URL) -> Bool = { _ in false }) -> Report {
        var report = Report()
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where RecordingLibrary.isRecording(folder) {
            if isBusy(folder) { report.skipped.append(folder); continue }
            let before = snapshot(folder)
            let after = migrate(folder: folder)
            if RecordingLayout(directory: after).directory != RecordingLayout(directory: folder).directory
                || snapshot(after) != before {
                report.migrated.append(after)
            }
        }
        return report
    }

    /// Enough of a folder to tell whether a migration changed it.
    private static func snapshot(_ folder: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: Moving the root

    /// Checks a move of every recording from `current` to `destination` before making it.
    public static func validateMove(from current: URL, to destination: URL) throws {
        let from = current.standardizedFileURL.resolvingSymlinksInPath().path
        let to = destination.standardizedFileURL.resolvingSymlinksInPath().path
        if from == to { throw MoveError.sameFolder }
        if to.hasPrefix(from + "/") { throw MoveError.insideCurrent }
        if from.hasPrefix(to + "/") { throw MoveError.containsCurrent }
        let fm = FileManager.default
        do { try fm.createDirectory(at: destination, withIntermediateDirectories: true) }
        catch { throw MoveError.notWritable(destination.path) }
        guard fm.isWritableFile(atPath: destination.path) else { throw MoveError.notWritable(destination.path) }
    }

    /// Moves each recording folder of `old` into `new` (a name already there gets " (2)"),
    /// then removes `old` only when nothing but `.DS_Store` is left in it. A folder that
    /// is busy stays; so does anything that is not a recording.
    public static func moveRoot(from old: URL, to new: URL, isBusy: (URL) -> Bool = { _ in false }) -> Report {
        var report = Report()
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return report }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        let folders = (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where RecordingLibrary.isRecording(folder) {
            if isBusy(folder) { report.skipped.append(folder); continue }
            let target = new.appendingPathComponent(RecordingLayout.uniqueName(folder.lastPathComponent, in: new))
            do {
                try fm.moveItem(at: folder, to: target)
                report.moved.append(target)
            } catch {
                report.failures.append("\(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let left = (try? fm.contentsOfDirectory(atPath: old.path)) ?? []
        if left.allSatisfy({ $0 == ".DS_Store" }) {
            try? fm.removeItem(at: old)
        }
        return report
    }

    /// The launch-time job for the default root: recordings kept on the Desktop move to
    /// `root`, then everything under `root` is brought into the layout.
    public static func run(
        root: URL, legacyRoot: URL = URL(filePath: Defaults.legacyOutputRoot.expandingTilde),
        movesLegacyRoot: Bool, isBusy: (URL) -> Bool = { _ in false }
    ) -> Report {
        var report = Report()
        if movesLegacyRoot, legacyRoot.standardizedFileURL != root.standardizedFileURL {
            report = moveRoot(from: legacyRoot, to: root, isBusy: isBusy)
        }
        let migrated = migrateAll(in: root, isBusy: isBusy)
        report.migrated += migrated.migrated
        report.skipped += migrated.skipped
        return report
    }
}
