import Foundation

/// What leaves the Mac when a recording is shared: the merged video (or audio) with the
/// transcript inside it as a captions track and the call's title, date and summary in its
/// metadata, beside `Summary.md` and `Transcript.md`.
///
/// The recording itself is never touched. The shared video is a stream copy of the merged
/// file into `Cache/Share/` — the picture and sound are not re-encoded, so a 38-minute call
/// took 1.3 s — with a `mov_text` subtitle track ("Maya: Can we ship…") that QuickTime,
/// browsers, VLC and OneDrive's player offer as captions. It is kept until something it was
/// made from changes (the merged file, the transcript or the summary renderings), then made
/// again, so a name corrected after sharing is in the next share. Without ffmpeg, or with
/// no transcript yet, the merged file itself is shared as it is.
public enum RecordingShare {
    public struct Set: Sendable, Equatable {
        /// The video or audio, the summary and the transcript, in that order; only those
        /// that exist.
        public let files: [URL]
        /// The name the files belong under when copied somewhere: the recording folder's.
        public let name: String
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case nothingToShare
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .nothingToShare: "This recording has no merged file to share yet."
            case .failed(let reason): "The shared copy could not be made: \(reason)"
            }
        }
    }

    static let folderName = "Share"
    static let signatureName = ".made-from"

    /// The share set for `directory`, made or reused.
    public static func prepare(_ directory: URL, ffmpeg: String? = Muxer.ffmpegPath()) async throws -> Set {
        let layout = RecordingLayout(directory: directory)
        let info = RecordingInfo.read(layout.directory)
        guard let media = RecordingMedia.merged(in: layout.directory, info: info) else { throw Failure.nothingToShare }
        let notes = [RecordingLayout.summaryMarkdown, RecordingLayout.transcriptMarkdown]
            .map { layout.directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let name = layout.directory.lastPathComponent

        guard let ffmpeg, let captions = TranscriptStore.srt(in: layout.directory), !captions.isEmpty else {
            return Set(files: [media] + notes, name: name)
        }
        let folder = layout.folder(.cache).appendingPathComponent(folderName)
        let shared = folder.appendingPathComponent(media.lastPathComponent)
        let signature = signature(of: [media] + notes, captions: captions)
        let signatureFile = folder.appendingPathComponent(signatureName)
        if FileManager.default.fileExists(atPath: shared.path),
           (try? String(contentsOf: signatureFile, encoding: .utf8)) == signature {
            return Set(files: [shared] + notes, name: name)
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: old)
        }
        let srt = folder.appendingPathComponent(".captions.srt")
        let temporary = folder.appendingPathComponent(".sharing-\(UUID().uuidString).\(media.pathExtension)")
        defer {
            try? FileManager.default.removeItem(at: srt)
            try? FileManager.default.removeItem(at: temporary)
        }
        try captions.write(to: srt, atomically: true, encoding: .utf8)

        let original = try await MediaFacts.read(media)
        let arguments = Self.arguments(
            media: media, captions: srt, output: temporary, video: !original.video.isEmpty,
            hevc: original.video.first?.isHEVC == true, metadata: metadata(in: layout.directory, info: info),
            language: captionLanguage(in: layout.directory))
        let result = try Shell.run(ffmpeg, arguments)
        guard result.succeeded else { throw Failure.failed(String(result.standardError.suffix(600))) }
        let copy = try await MediaFacts.read(temporary)
        if let problem = problem(with: copy, original: original) { throw Failure.failed(problem) }
        try FileManager.default.moveItem(at: temporary, to: shared)
        try signature.write(to: signatureFile, atomically: true, encoding: .utf8)
        return Set(files: [shared] + notes, name: name)
    }

    static func arguments(
        media: URL, captions: URL, output: URL, video: Bool, hevc: Bool, metadata: [String: String],
        language: String? = nil
    ) -> [String] {
        var args = ["-nostdin", "-y", "-i", media.path, "-i", captions.path]
        if video { args += ["-map", "0:v:0"] }
        args += ["-map", "0:a?", "-map", "1:s", "-c", "copy", "-c:s", "mov_text"]
        /// AVFoundation will not play HEVC tagged `hev1`, ffmpeg's default.
        if hevc { args += ["-tag:v", "hvc1"] }
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) { args += ["-metadata", "\(key)=\(value)"] }
        args += ["-metadata:s:s:0", "handler_name=Transcript"]
        if let language { args += ["-metadata:s:s:0", "language=\(language)"] }
        args += ["-movflags", "+faststart", output.path]
        return args
    }

    /// The transcript's language as the three-letter code MP4 tracks carry ("en" → "eng");
    /// nil when the engine reported none, as Parakeet does, which leaves it undetermined.
    static func captionLanguage(in directory: URL) -> String? {
        guard let code = RecordingTranscript.read(in: directory)?.named.language else { return nil }
        return Locale.LanguageCode(code).identifier(.alpha3)
    }

    /// Title, date, and the summary's overview as comment and description.
    static func metadata(in directory: URL, info: RecordingInfo?) -> [String: String] {
        var values: [String: String] = [:]
        if let info {
            values["title"] = RecordingMedia.cleanTitle(info.title, app: info.appName)
        }
        if let started = RecordingLibrary.knownStart(directory, info: info) {
            values["date"] = ISO8601DateFormatter().string(from: started)
        }
        if let url = TranscriptStore.activeSummary(in: directory), url.pathExtension == "json",
           let summary = Summary.read(url) {
            let names = RecordingTranscript.read(in: directory)?.voices?.names ?? [:]
            let overview = summary.named(names).overview.trimmingCharacters(in: .whitespacesAndNewlines)
            if !overview.isEmpty {
                values["comment"] = overview
                values["description"] = overview
            }
        }
        values["encoder"] = "AnyRec"
        return values
    }

    /// The stream copy has the original's picture frame for frame and its sound unchanged.
    static func problem(with copy: MediaFacts, original: MediaFacts) -> String? {
        guard copy.video.count == original.video.count else { return "it has \(copy.video.count) video streams" }
        if let video = copy.video.first, let reference = original.video.first {
            guard video.codec == reference.codec, video.width == reference.width, video.height == reference.height else {
                return "its video changed"
            }
            if let frames = video.frames, let expected = reference.frames, frames != expected {
                return "its video has \(frames) frames, not \(expected)"
            }
        }
        guard copy.audio.count == original.audio.count else { return "it has \(copy.audio.count) audio streams" }
        for (a, b) in zip(copy.audio, original.audio) where abs(a - b) > MergeVerification.audioTolerance {
            return String(format: "its audio runs %.2f s, not %.2f s", a, b)
        }
        return nil
    }

    /// Sizes and modification times of what the copy is made from, and the captions'
    /// text, so a rename in the transcript makes a new copy.
    static func signature(of files: [URL], captions: String) -> String {
        let parts = files.map { url -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(url.lastPathComponent)|\(size)|\(date)"
        }
        return (parts + ["captions|\(captions.hashValue)"]).joined(separator: "\n")
    }
}

/// The folders a cloud service keeps in sync on this Mac, which a share set can be copied
/// into: OneDrive's (one per signed-in account, under `~/Library/CloudStorage`) and iCloud
/// Drive's. The service's own app does the uploading. OneDrive installs no share
/// extension, so this is how it reaches the Share menu at all.
public struct CloudFolder: Sendable, Equatable, Identifiable {
    public enum Service: Sendable, Equatable {
        case oneDrive
        case iCloudDrive
    }

    public let service: Service
    /// "OneDrive", "OneDrive – Blueprint", "iCloud Drive".
    public let name: String
    public let url: URL
    public var id: String { url.path }

    public static func available(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CloudFolder] {
        let fm = FileManager.default
        var folders: [CloudFolder] = []
        let storage = home.appendingPathComponent("Library/CloudStorage")
        let entries = ((try? fm.contentsOfDirectory(atPath: storage.path)) ?? []).sorted()
        for entry in entries where entry.hasPrefix("OneDrive") {
            let account = entry.dropFirst("OneDrive".count).drop { $0 == "-" || $0 == " " }
            let name = account.isEmpty || account == "Personal" ? "OneDrive" : "OneDrive – \(account)"
            folders.append(CloudFolder(service: .oneDrive, name: name, url: storage.appendingPathComponent(entry)))
        }
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) {
            folders.append(CloudFolder(service: .iCloudDrive, name: "iCloud Drive", url: iCloud))
        }
        return folders
    }

    /// Copies the set into `AnyRec/<recording>/` in this folder, replacing an earlier copy
    /// of the same files, and returns that folder.
    @discardableResult
    public func save(_ set: RecordingShare.Set) throws -> URL {
        let fm = FileManager.default
        let target = url.appendingPathComponent("AnyRec").appendingPathComponent(set.name)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for file in set.files {
            let destination = target.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: file, to: destination)
        }
        return target
    }
}
