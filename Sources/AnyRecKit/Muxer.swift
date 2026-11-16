import Foundation

public enum MuxError: Error, LocalizedError, CustomStringConvertible {
    case ffmpegNotFound
    case nothingToMerge
    case failed(status: Int32, log: String)
    /// A source could not be read, so nothing was written.
    case unreadable(URL, String)
    /// ffmpeg finished, but its file does not hold what it was made from. Nothing was
    /// replaced or deleted.
    case unverified(String)

    public var description: String {
        switch self {
        case .ffmpegNotFound: "ffmpeg is not on PATH. Install it with `brew install ffmpeg`."
        case .nothingToMerge: "No track was recorded, so there is nothing to merge."
        case .failed(let status, let log): "ffmpeg exited with \(status):\n\(log)"
        case .unreadable(let url, let reason): "\(url.lastPathComponent) could not be read: \(reason)"
        case .unverified(let reason): "The merged file was not kept: \(reason). The recording is unchanged."
        }
    }

    public var errorDescription: String? { description }
}

/// The merged file, plus anything the merge learned about the recording.
public struct MuxOutcome: Sendable {
    public let output: URL
    public let notes: [String]
    /// Files the verified merge replaced and deleted: `screen.mov`, and an earlier merged
    /// file under another name.
    public let replaced: [URL]

    public init(output: URL, notes: [String], replaced: [URL] = []) {
        self.output = output
        self.notes = notes
        self.replaced = replaced
    }
}

/// What one merge reads and writes.
public struct MergeJob: Sendable, Equatable {
    /// Where the picture is copied from: `screen.mov`, or once that is gone the merged
    /// file that replaced it. Nil for audio only.
    public let video: URL?
    /// The video stream the result must match frame for frame.
    public let reference: MediaFacts.Video?
    public let audio: [URL]
    public let output: URL
}

/// Folds the separate tracks into one playable file, named from the recording, which
/// then replaces `screen.mov` as the video master. The audio tracks are never rewritten.
public enum Muxer {
    public static func ffmpegPath() -> String? {
        /// A package manager's first, then the one the app fetched itself.
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg", FFmpegSetup.path.path]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// What a merge of this folder reads and where it writes. The picture comes from
    /// `screen.mov` while it exists; after a verified merge has deleted it, from the
    /// merged file, so a merge can be run again without the video ever being lost.
    public static func job(for plan: OutputPlan) async throws -> MergeJob {
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        let info = RecordingInfo.read(plan.directory)
        let merged = RecordingMedia.merged(in: plan.directory, info: info)
        let audio = [plan.systemAudio, plan.microphone].filter(exists)

        var video: (url: URL, facts: MediaFacts.Video)?
        if exists(plan.screen) {
            video = (plan.screen, try await onlyVideo(of: plan.screen))
        } else if let merged, info?.audioOnly != true {
            let facts = try await read(merged)
            if facts.video.count > 1 { throw MuxError.unreadable(merged, "it has \(facts.video.count) video streams") }
            video = facts.video.first.map { (merged, $0) }
        }
        guard video != nil || !audio.isEmpty else { throw MuxError.nothingToMerge }

        let audioOnly = video == nil
        let wanted = audioOnly ? "m4a" : "mp4"
        let name = info?.mergedFile.flatMap { ($0 as NSString).pathExtension == wanted ? $0 : nil }
            ?? RecordingMedia.mergedName(in: plan.directory, info: info, audioOnly: audioOnly)
        return MergeJob(video: video?.url, reference: video?.facts, audio: audio,
                        output: plan.directory.appendingPathComponent(name))
    }

    /// Video is stream-copied; the audio tracks are mixed down to one stereo AAC track.
    /// Without a picture the result is the mixed audio alone, from the same `MixPlan`.
    public static func arguments(for job: MergeJob, mix: MixPlan = .plain, writingTo output: URL) -> [String] {
        var args = ["-nostdin", "-y"]
        if let video = job.video { args += ["-i", video.path] }
        args += job.audio.flatMap { ["-i", $0.path] }

        /// Inputs are numbered from the first audio track once there is no video ahead of it.
        let first = job.video == nil ? 0 : 1
        /// The first video stream only: a merged file being merged again carries the old
        /// mix as well, which is replaced, never copied.
        if job.video != nil { args += ["-map", "0:v:0"] }
        if job.audio.count > 1 {
            args += ["-filter_complex", mix.filter(systemAudio: first, microphone: first + 1), "-map", "[a]"]
        } else if job.audio.count == 1 {
            args += ["-map", "\(first):a"]
        }

        if job.video != nil {
            args += ["-c:v", "copy"]
            /// AVFoundation will not play HEVC tagged `hev1`, which is ffmpeg's default for
            /// HEVC in an MP4 when the source's tag is not carried over. Current builds keep
            /// `screen.mov`'s `hvc1` on a copy; this holds it for any build that does not.
            if job.reference?.isHEVC == true { args += ["-tag:v", "hvc1"] }
        }
        if !job.audio.isEmpty { args += ["-c:a", "aac", "-b:a", "192k"] }
        args.append(output.path)
        return args
    }

    /// Writes the merge beside the tracks under a hidden temporary name, checks it holds
    /// every frame of the picture and the whole mix, then moves it into place, records its
    /// name in `recording.json`, and only then deletes what it replaces — `screen.mov`, or
    /// an older merged file. A failure anywhere before that leaves the folder as it was;
    /// an interruption leaves at worst a stray temporary file.
    @discardableResult
    public static func mux(_ plan: OutputPlan) async throws -> MuxOutcome {
        guard let ffmpeg = ffmpegPath() else { throw MuxError.ffmpegNotFound }
        let mix = decision(for: plan, using: ffmpeg)
        let job = try await job(for: plan)
        let expectedAudio = try await audioLength(of: job.audio, systemAudio: plan.systemAudio, mix: mix)
        let temporary = plan.directory.appendingPathComponent(
            ".merge-\(UUID().uuidString).\(job.output.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        try run(ffmpeg, arguments(for: job, mix: mix, writingTo: temporary))
        let result = try await read(temporary)
        if let problem = MergeVerification.problem(with: result, video: job.reference, audio: expectedAudio) {
            throw MuxError.unverified(problem)
        }
        let replaced = try publish(temporary, as: job, in: plan)
        return MuxOutcome(output: job.output, notes: mix.notes, replaced: replaced)
    }

    /// The verified file goes into place first, its name into `recording.json` second, and
    /// the files it replaces go last, so there is never a moment without a playable file
    /// holding the picture.
    private static func publish(_ temporary: URL, as job: MergeJob, in plan: OutputPlan) throws -> [URL] {
        let manager = FileManager.default
        var info = RecordingInfo.read(plan.directory)
        let previous = RecordingMedia.merged(in: plan.directory, info: info)
        let existed = manager.fileExists(atPath: job.output.path)
        if existed {
            _ = try manager.replaceItemAt(job.output, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: job.output)
        }
        let name = job.output.lastPathComponent
        if info != nil, name != RecordingMedia.legacyMergedName, info?.mergedFile != name {
            info?.mergedFile = name
            do { try info?.write(to: plan.directory) } catch {
                /// Unnamed in `recording.json`, the new file is one no reader finds.
                if !existed { try? manager.removeItem(at: job.output) }
                throw error
            }
        }

        var superseded: [URL] = []
        if job.reference != nil, manager.fileExists(atPath: plan.screen.path) { superseded.append(plan.screen) }
        if let previous, previous.standardizedFileURL != job.output.standardizedFileURL { superseded.append(previous) }
        return superseded.filter { (try? manager.removeItem(at: $0)) != nil }
    }

    private static func run(_ ffmpeg: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = args
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        /// ffmpeg reads the terminal for interactive keys, which steals them from us
        /// and blocks when the terminal is in raw mode.
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MuxError.failed(status: process.terminationStatus, log: String(log.suffix(2_000)))
        }
    }

    private static func read(_ url: URL) async throws -> MediaFacts {
        do { return try await MediaFacts.read(url) }
        catch { throw MuxError.unreadable(url, error.localizedDescription) }
    }

    private static func onlyVideo(of url: URL) async throws -> MediaFacts.Video {
        let facts = try await read(url)
        guard facts.video.count == 1, let video = facts.video.first else {
            throw MuxError.unreadable(url, "it has \(facts.video.count) video streams, not one")
        }
        return video
    }

    /// The mix runs to the longest track, each as long as it is once moved into line.
    private static func audioLength(of tracks: [URL], systemAudio: URL, mix: MixPlan) async throws -> TimeInterval? {
        guard !tracks.isEmpty else { return nil }
        var longest: TimeInterval = 0
        for track in tracks {
            let length = try await read(track).audio.max() ?? 0
            longest = max(longest, tracks.count > 1 ? mix.length(of: length, systemAudio: track == systemAudio) : length)
        }
        return longest
    }

    /// With one track there is nothing to balance against.
    private static func decision(for plan: OutputPlan, using ffmpeg: String) -> MixPlan {
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        guard exists(plan.systemAudio), exists(plan.microphone) else { return .plain }
        return MixPlan.decided(for: plan, using: ffmpeg)
    }
}
