import Foundation

/// Re-encodes a recording's merged video with x265, about fifteen times smaller, once the
/// merged file has become the only copy of the picture.
///
/// The hardware encoder that records the screen spends bits on every frame, and a call's
/// frames barely change: a 76-minute call came out at 1.4 GB. x265 at CRF 28 made a
/// three-minute excerpt of it 4.1 MB instead of 60 MB, with an SSIM of 0.995 and text in a
/// shared screen as sharp as before (compared crop by crop). Apple's hardware HEVC at any
/// bitrate stayed at a quarter to a third of the size or worse. Full resolution is kept:
/// scaling a Retina capture down to 1920 pixels smudged small text. `veryfast` gave the
/// same size as `fast` in three quarters of the time.
///
/// It is the merge's discipline again: a hidden temporary file beside the original,
/// checked for every frame at the same size and the audio untouched, swapped in under the
/// same name, and only then marked in `recording.json`. Cancelling at any point leaves the
/// folder as it was. The audio stream is copied, never re-encoded, and the tracks are not
/// touched; a later merge copies this video as it copied the old one.
public enum Compression {
    public static let preset = "veryfast"
    public static let quality = 28
    /// Below this share of the original the result is kept; above, the original stays and
    /// the recording is marked done, because re-encoding again would not help either.
    public static let worthwhile = 0.8

    public enum Outcome: Sendable, Equatable {
        /// Replaced: the file's size before and after.
        case compressed(before: Int64, after: Int64)
        /// The result was not small enough to be worth the generation loss.
        case notWorthwhile(before: Int64, after: Int64)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case noEncoder
        case failed(status: Int32, log: String)
        case unverified(String)

        public var errorDescription: String? {
            switch self {
            case .noEncoder: "This ffmpeg has no x265 encoder."
            case .failed(let status, let log): "ffmpeg exited with \(status): \(log)"
            case .unverified(let reason): "The compressed file was not kept: \(reason). The recording is unchanged."
            }
        }
    }

    /// The merged file to compress, when there is one worth doing: video, the only copy of
    /// the picture (no `screen.mov` beside it, so a later merge cannot bring the original
    /// back), and not done before. Older folders that keep `screen.mov` beside `call.mp4`
    /// are left as they are.
    public static func candidate(in directory: URL) -> URL? {
        guard let info = RecordingInfo.read(directory), !info.audioOnly, !info.compressed,
              !FileManager.default.fileExists(atPath: OutputPlan(directory: directory).screen.path),
              let merged = RecordingMedia.merged(in: directory, info: info),
              merged.pathExtension == "mp4"
        else { return nil }
        return merged
    }

    /// A third of the cores, at least two. At utility priority with four threads, three
    /// minutes of a 1646×1330 call took 70 s; at background priority (efficiency cores
    /// only) 170 s, so a long call interrupted by the next one would rarely finish; at
    /// utility on every core 44 s, with the fans to match. Same file every time.
    public static var threads: Int { max(2, ProcessInfo.processInfo.activeProcessorCount / 3) }

    public static func arguments(input: URL, output: URL, threads: Int = threads) -> [String] {
        [
            "-nostdin", "-y", "-threads", "2", "-i", input.path,
            "-map", "0:v:0", "-map", "0:a?",
            /// Every frame at its own time: the capture's frame rate varies with what changed,
            /// and the check below compares frame counts.
            "-fps_mode", "passthrough",
            "-c:v", "libx265", "-preset", preset, "-crf", "\(quality)",
            "-x265-params", "log-level=error:pools=\(threads):frame-threads=2",
            /// AVFoundation will not play HEVC tagged `hev1`, ffmpeg's default.
            "-tag:v", "hvc1",
            "-c:a", "copy",
            "-movflags", "+faststart",
            output.path,
        ]
    }

    public static func hasEncoder(_ ffmpeg: String) -> Bool {
        (try? Shell.run(ffmpeg, ["-hide_banner", "-encoders"]))?.standardOutput.contains(" libx265 ") == true
    }

    /// Compresses `directory`'s merged video. Throws `CancellationError` when the task is
    /// cancelled, which stops ffmpeg at once; nothing is changed until the end.
    public static func compress(_ directory: URL, using ffmpeg: String) async throws -> Outcome {
        guard let merged = candidate(in: directory) else { throw CancellationError() }
        guard hasEncoder(ffmpeg) else { throw Failure.noEncoder }
        let original = try await MediaFacts.read(merged)
        guard original.video.count == 1, let reference = original.video.first else {
            throw Failure.unverified("the merged file has \(original.video.count) video streams")
        }
        let temporary = directory.appendingPathComponent(".compress-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }

        try await run(ffmpeg, arguments(input: merged, output: temporary))
        try Task.checkCancellation()
        let result = try await MediaFacts.read(temporary)
        if let problem = problem(with: result, original: original, reference: reference) {
            throw Failure.unverified(problem)
        }

        let before = size(of: merged), after = size(of: temporary)
        guard Double(after) < Double(before) * worthwhile else {
            try mark(directory)
            return .notWorthwhile(before: before, after: after)
        }
        /// The name stays, so `recording.json`'s `mergedFile` still finds it. The swap is
        /// atomic: there is never a moment without a playable file holding the picture.
        _ = try FileManager.default.replaceItemAt(merged, withItemAt: temporary)
        try mark(directory)
        return .compressed(before: before, after: after)
    }

    /// Nil when `result` holds the original's picture, frame for frame at the same size in
    /// HEVC, and its audio unchanged in length.
    static func problem(with result: MediaFacts, original: MediaFacts, reference: MediaFacts.Video) -> String? {
        guard result.video.count == 1, let video = result.video.first else {
            return "it has \(result.video.count) video streams, not one"
        }
        guard video.isHEVC else { return "its video is \(MergeVerification.fourCC(video.codec)), not HEVC" }
        guard video.width == reference.width, video.height == reference.height else {
            return "its video is \(video.width)×\(video.height), not \(reference.width)×\(reference.height)"
        }
        if let frames = video.frames, let expected = reference.frames {
            guard frames == expected else { return "its video has \(frames) frames, not \(expected)" }
        } else if abs(video.duration - reference.duration) > reference.frameDuration {
            return String(format: "its video runs %.2f s, not %.2f s", video.duration, reference.duration)
        }
        guard result.audio.count == original.audio.count else {
            return "it has \(result.audio.count) audio streams, not \(original.audio.count)"
        }
        for (copied, source) in zip(result.audio, original.audio)
        where abs(copied - source) > MergeVerification.audioTolerance {
            return String(format: "its audio runs %.2f s, not %.2f s", copied, source)
        }
        return nil
    }

    /// Hidden temporary files a compression left behind when the app was stopped mid-way.
    public static func leftovers(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(".compress-") }
    }

    private static func mark(_ directory: URL) throws {
        guard var info = RecordingInfo.read(directory) else { return }
        info.compressed = true
        try info.write(to: directory)
    }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// ffmpeg at utility priority on `threads` cores, below anything the person is doing,
    /// stopped when the task is cancelled. Its log goes to a file, not a pipe nobody drains.
    private static func run(_ ffmpeg: String, _ arguments: [String]) async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-compress-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        process.qualityOfService = .utility

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                guard !Task.isCancelled else {
                    process.terminationHandler = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            /// SIGTERM makes ffmpeg finish encoding what it has queued — fourteen seconds on
            /// a 720p test — and the file is discarded anyway. (`terminate` on a process that
            /// never started would also raise.)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try Task.checkCancellation()
        guard status == 0 else {
            let tail = (try? String(contentsOf: log, encoding: .utf8)).map { String($0.suffix(1_000)) } ?? ""
            throw Failure.failed(status: status, log: tail)
        }
    }
}
