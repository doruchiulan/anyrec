import Foundation

extension SharedMeeting {
    public func playableFile(in directory: URL) async throws -> URL {
        let file = directory.appendingPathComponent(mediaName)
        try SharedFiles.check(directory)
        try SharedFiles.check(file)
        let deadline = ContinuousClock.now + .seconds(90)
        while try SharedFiles.requestDownload(file) {
            guard ContinuousClock.now < deadline else {
                throw RecordingShare.Failure.failed("The cloud provider is still downloading the recording.")
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        try SharedFiles.requireFile(file)
        return file
    }
}

extension SharedFiles {
    static func requestDownload(_ url: URL) throws -> Bool {
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        if status == .notDownloaded || (!fm.fileExists(atPath: url.path) && fm.fileExists(atPath: placeholder.path)) {
            try fm.startDownloadingUbiquitousItem(at: url)
            return true
        }
        return false
    }

    static func requireFile(_ url: URL) throws {
        try check(url)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnknown)
        }
    }
}
