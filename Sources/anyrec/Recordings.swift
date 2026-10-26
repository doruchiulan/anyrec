import Foundation

/// Where the commands that work on a finished recording find one.
enum Recordings {
    static func newest(in root: URL) -> URL? {
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
        return
            folders
            .filter { isDirectory($0) && $0.lastPathComponent.hasPrefix("rec-") }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `URL.hasDirectoryPath` only looks at the trailing slash, which a path typed
    /// on the command line will not have.
    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        return exists && directory.boolValue
    }
}
