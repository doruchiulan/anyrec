import AnyRecKit
import Foundation

/// Where the commands that work on a finished recording find one.
enum Recordings {
    static func newest(in root: URL) -> URL? {
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
        let found = folders
            .filter(RecordingLibrary.isRecording)
            .max { (RecordingLibrary.started($0), $0.lastPathComponent) < (RecordingLibrary.started($1), $1.lastPathComponent) }
        if found != nil { return found }
        /// The default root moved off the Desktop; the app moves what is there, and until it
        /// has, the terminal still finds it.
        let legacy = URL(filePath: Defaults.legacyOutputRoot.expandingTilde)
        if root.standardizedFileURL == URL(filePath: Defaults.outputRoot.expandingTilde).standardizedFileURL {
            return newest(in: legacy)
        }
        return nil
    }

    /// A folder about to be written to, brought into the current layout first (and given
    /// its readable name). Anything that is not a recording folder is returned as it is.
    static func prepared(_ folder: URL) -> URL {
        guard isDirectory(folder), RecordingLibrary.isRecording(folder) else { return folder }
        return RecordingMigration.migrate(folder: folder)
    }

    /// `URL.hasDirectoryPath` only looks at the trailing slash, which a path typed
    /// on the command line will not have.
    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        return exists && directory.boolValue
    }
}
