import Foundation

/// Where one file kept by a cloud provider stands, read from the file system's own facts,
/// which every File Provider app answers (iCloud Drive, OneDrive, Google Drive, Dropbox,
/// Box). Nothing here opens a file: opening one that is only in the cloud blocks until it
/// has arrived.
public enum CloudFile {
    public enum Download: Sendable, Equatable {
        /// On this Mac, whole.
        case local
        /// In the cloud, not on this Mac.
        case remote
        case downloading
        /// The provider has no such file, here or in the cloud: not uploaded yet, or gone.
        case missing
        case failed(String)
    }

    public enum Upload: Sendable, Equatable {
        /// Not in a cloud folder; being written is all there is to wait for.
        case notCloud
        case waiting
        case uploading
        case uploaded
        case failed(String)
    }

    private static let keys: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemDownloadingErrorKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
        .ubiquitousItemUploadingErrorKey,
    ]

    /// Read afresh each time: a `URL` keeps the values it was asked for first, and a file
    /// that had arrived went on reading as not downloaded.
    private static func values(_ url: URL) -> URLResourceValues? {
        var url = URL(fileURLWithPath: url.path)
        url.removeAllCachedResourceValues()
        return try? url.resourceValues(forKeys: keys)
    }

    /// Present but with nothing on disk: reading it would fetch it.
    static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }

    private static func placeholder(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }

    public static func download(_ url: URL) -> Download {
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard exists || FileManager.default.fileExists(atPath: placeholder(url).path) else { return .missing }
        let facts = values(url)
        let remote = !exists || isDataless(url)
            || (facts?.isUbiquitousItem == true && facts?.ubiquitousItemDownloadingStatus == .notDownloaded)
        guard remote else { return .local }
        if facts?.ubiquitousItemIsDownloading == true { return .downloading }
        if let error = facts?.ubiquitousItemDownloadingError { return .failed(error.localizedDescription) }
        return .remote
    }

    public static func requestDownload(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    public static func upload(_ url: URL) -> Upload {
        guard FileManager.default.fileExists(atPath: url.path), let facts = values(url) else { return .waiting }
        guard facts.isUbiquitousItem == true else { return .notCloud }
        if let error = facts.ubiquitousItemUploadingError { return .failed(error.localizedDescription) }
        if facts.ubiquitousItemIsUploading == true { return .uploading }
        return facts.ubiquitousItemIsUploaded == true ? .uploaded : .waiting
    }
}

/// How far a synced recording's files have got, taken together: it is up only when every
/// one of them is, the tracks included.
public enum SharedUpload: Sendable, Equatable {
    case notCloud
    case uploading(done: Int64, total: Int64)
    case uploaded
    case failed(String)

    /// `files` with their sizes, and how much of each is up where its provider says.
    static func of(_ files: [(state: CloudFile.Upload, size: Int64, fraction: Double)]) -> SharedUpload {
        for case (.failed(let reason), _, _) in files { return .failed(reason) }
        let pending = files.contains { $0.state == .waiting || $0.state == .uploading }
        if pending {
            let done = files.reduce(Int64(0)) { sum, file in
                let whole = file.state == .uploaded || file.state == .notCloud
                return sum + (whole ? file.size : Int64(Double(file.size) * min(1, max(0, file.fraction))))
            }
            return .uploading(done: done, total: files.reduce(0) { $0 + $1.size })
        }
        return files.contains { $0.state == .uploaded } ? .uploaded : .notCloud
    }

    /// Several shared copies taken together: failed if any did, going up while any is, up
    /// once one is and none is still going. Nil when there are none.
    public static func combined(_ copies: [SharedUpload]) -> SharedUpload? {
        guard !copies.isEmpty else { return nil }
        for case .failed(let reason) in copies { return .failed(reason) }
        let going = copies.compactMap { if case .uploading(let done, let total) = $0 { (done, total) } else { nil } }
        if !going.isEmpty { return .uploading(done: going.reduce(0) { $0 + $1.0 }, total: going.reduce(0) { $0 + $1.1 }) }
        return copies.contains(.uploaded) ? .uploaded : .notCloud
    }
}
