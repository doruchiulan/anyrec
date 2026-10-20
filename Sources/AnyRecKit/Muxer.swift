import Foundation

public enum MuxError: Error, CustomStringConvertible {
    case ffmpegNotFound
    case noVideo
    case failed(status: Int32, log: String)

    public var description: String {
        switch self {
        case .ffmpegNotFound: "ffmpeg is not on PATH. Install it with `brew install ffmpeg`."
        case .noVideo: "No screen track was recorded, nothing to mux."
        case .failed(let status, let log): "ffmpeg exited with \(status):\n\(log)"
        }
    }
}

/// The merged file, plus anything the merge learned about the recording.
public struct MuxOutcome: Sendable {
    public let output: URL
    public let notes: [String]
}

/// Optional post-pass that folds the separate tracks into one playable file.
public enum Muxer {
    public static func ffmpegPath() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Video is stream-copied; the audio tracks are mixed down to one stereo AAC track.
    public static func arguments(
        for plan: OutputPlan, mix: MixPlan = .plain
    ) throws -> (args: [String], output: URL) {
        let exists = { FileManager.default.fileExists(atPath: $0) }
        guard exists(plan.screen.path) else { throw MuxError.noVideo }

        let audio = [plan.systemAudio, plan.microphone].filter { exists($0.path) }
        let output = plan.directory.appendingPathComponent("call.mp4")

        var args = ["-nostdin", "-y", "-i", plan.screen.path]
        args += audio.flatMap { ["-i", $0.path] }

        if audio.count > 1 {
            args += [
                "-filter_complex", mix.filter(systemAudio: 1, microphone: 2),
                "-map", "0:v", "-map", "[a]",
            ]
        } else if audio.count == 1 {
            args += ["-map", "0:v", "-map", "1:a"]
        } else {
            args += ["-map", "0:v"]
        }

        args += ["-c:v", "copy"]
        if !audio.isEmpty { args += ["-c:a", "aac", "-b:a", "192k"] }
        args.append(output.path)
        return (args, output)
    }

    @discardableResult
    public static func mux(_ plan: OutputPlan) throws -> MuxOutcome {
        guard let ffmpeg = ffmpegPath() else { throw MuxError.ffmpegNotFound }
        let mix = decision(for: plan, using: ffmpeg)
        let (args, output) = try arguments(for: plan, mix: mix)

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
        return MuxOutcome(output: output, notes: mix.notes)
    }

    /// With one track there is nothing to balance against.
    private static func decision(for plan: OutputPlan, using ffmpeg: String) -> MixPlan {
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        guard exists(plan.systemAudio), exists(plan.microphone) else { return .plain }
        return MixPlan.decide(
            systemAudio: plan.systemAudio, microphone: plan.microphone,
            live: MicrophoneLive.read(plan.microphoneLive), using: ffmpeg)
    }
}
