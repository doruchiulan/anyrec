import Foundation

extension SharedMeeting {
    /// Every file a copy is made of, fetched. `waiting` is how long one that has not been
    /// uploaded yet is waited for.
    public func localFiles(in directory: URL) async throws {
        try SharedFiles.check(directory)
        let names = [mediaName] + [Self.callTrack, Self.microphoneTrack].filter { files?[$0] != nil }
        for name in names { try await Self.fetch(directory.appendingPathComponent(name)) }
    }

    /// The recording, once it is on this Mac. Waits as long as its provider takes: a call is
    /// hundreds of megabytes, and giving up at ninety seconds failed on any slow connection.
    public func playableFile(in directory: URL) async throws -> URL {
        let file = directory.appendingPathComponent(mediaName)
        try SharedFiles.check(directory)
        try await Self.fetch(file)
        return file
    }

    static func fetch(_ file: URL) async throws {
        try SharedFiles.check(file)
        var requested = false
        while true {
            switch CloudFile.download(file) {
            case .local:
                try SharedFiles.requireFile(file)
                return
            case .missing: throw RecordingShare.Failure.notUploaded
            case .failed(let reason) where requested: throw RecordingShare.Failure.download(reason)
            case .remote where !requested, .failed:
                try CloudFile.requestDownload(file)
                requested = true
            case .remote, .downloading: break
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }
}

extension SharedFiles {
    /// Asks for a file that is only in the cloud; true while it has not arrived.
    static func requestDownload(_ url: URL) throws -> Bool {
        switch CloudFile.download(url) {
        case .remote, .failed:
            try CloudFile.requestDownload(url)
            return true
        case .downloading: return true
        case .local, .missing: return false
        }
    }

    static func requireFile(_ url: URL) throws {
        try check(url)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnknown)
        }
    }
}
