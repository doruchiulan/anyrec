import CryptoKit
import Foundation

/// Fetching a file the tool needs but does not ship: whisper models, which are
/// hundreds of megabytes and have to arrive intact.
public enum AssetDownload {
    public struct Asset: Sendable, Equatable {
        public let name: String
        public let url: URL
        public let sha256: String
        public let bytes: Int64

        public init(name: String, url: URL, sha256: String, bytes: Int64) {
            self.name = name
            self.url = url
            self.sha256 = sha256
            self.bytes = bytes
        }
    }

    public enum Failure: Error, LocalizedError, CustomStringConvertible {
        case refused(name: String, status: Int)
        case corrupt(name: String)

        public var description: String {
            switch self {
            case .refused(let name, let status):
                "\(name) could not be downloaded — the server answered HTTP \(status)."
            case .corrupt(let name):
                "\(name) arrived damaged and was discarded. Try again."
            }
        }

        public var errorDescription: String? { description }
    }

    /// The file only appears at its final path once its checksum matches: a half-written
    /// model is worse than no model, because whisper picks the largest one it finds.
    public static func fetch(
        _ asset: Asset, into directory: URL, progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(asset.name)
        let arrived = try await withCheckedThrowingContinuation { continuation in
            let observer = Observer(asset: asset, progress: progress, continuation: continuation)
            let session = URLSession(
                configuration: .default, delegate: observer, delegateQueue: nil)
            session.downloadTask(with: asset.url).resume()
        }

        defer { try? FileManager.default.removeItem(at: arrived) }
        guard try digest(of: arrived) == asset.sha256.lowercased() else {
            throw Failure.corrupt(name: asset.name)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: arrived, to: destination)
        /// A model is not a secret, and the file URLSession hands over is private to
        /// the process — left alone, a downloaded model differs from a fetched one.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: destination.path)
        return destination
    }

    public static func describe(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_000_000
        return megabytes < 1
            ? "\(max(1, bytes / 1_000)) KB"
            : "\(Int(megabytes.rounded())) MB"
    }

    private static func digest(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        var hasher = SHA256()
        while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The download is driven by a delegate rather than `URLSession.download(from:)`
/// because that one reports no progress, and 574 MB with no sign of life reads as a hang.
private final class Observer: NSObject, URLSessionDownloadDelegate {
    private let asset: AssetDownload.Asset
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    init(
        asset: AssetDownload.Asset, progress: @escaping @Sendable (Int64) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.asset = asset
        self.progress = progress
        self.continuation = continuation
    }

    /// The temporary file is deleted the moment this returns, so it is moved aside
    /// here and verified afterwards.
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo url: URL
    ) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            return finish(.failure(AssetDownload.Failure.refused(name: asset.name, status: status)))
        }
        let held = FileManager.default.temporaryDirectory
            .appendingPathComponent("anyrec-asset-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: url, to: held)
            finish(.success(held))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytes: Int64,
        totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64
    ) {
        progress(written)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        if let error { finish(.failure(error)) }
        session.finishTasksAndInvalidate()
    }

    /// Both delegate callbacks fire on a success, and resuming a continuation twice traps.
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
