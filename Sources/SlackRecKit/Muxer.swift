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

/// Optional post-pass that folds the separate tracks into one playable file.
public enum Muxer {
    public static func ffmpegPath() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Video is stream-copied; the audio tracks are mixed down to one stereo AAC track.
    public static func arguments(for plan: OutputPlan) throws -> (args: [String], output: URL) {
        let exists = { FileManager.default.fileExists(atPath: $0) }
        guard exists(plan.screen.path) else { throw MuxError.noVideo }

        let audio = [plan.systemAudio, plan.microphone].filter { exists($0.path) }
        let output = plan.directory.appendingPathComponent("call.mp4")

        var args = ["-nostdin", "-y", "-i", plan.screen.path]
        args += audio.flatMap { ["-i", $0.path] }

        if audio.count > 1 {
            let inputs = (1...audio.count).map { "[\($0):a]" }.joined()
            args += [
                "-filter_complex",
                "\(inputs)amix=inputs=\(audio.count):duration=longest:normalize=0[a]",
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
    public static func mux(_ plan: OutputPlan) throws -> URL {
        guard let ffmpeg = ffmpegPath() else { throw MuxError.ffmpegNotFound }
        let (args, output) = try arguments(for: plan)

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
        return output
    }
}
