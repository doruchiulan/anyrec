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
        for plan: OutputPlan, gains: TrackGains = .none
    ) throws -> (args: [String], output: URL) {
        let exists = { FileManager.default.fileExists(atPath: $0) }
        guard exists(plan.screen.path) else { throw MuxError.noVideo }

        let audio = [(plan.systemAudio, gains.systemAudio), (plan.microphone, gains.microphone)]
            .filter { exists($0.0.path) }
        let output = plan.directory.appendingPathComponent("call.mp4")

        var args = ["-nostdin", "-y", "-i", plan.screen.path]
        args += audio.flatMap { ["-i", $0.0.path] }

        if audio.count > 1 {
            args += ["-filter_complex", mix(audio), "-map", "0:v", "-map", "[a]"]
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

    /// Each gain rides in as its own `volume` stage; a gain of zero adds no stage at all.
    private static func mix(_ audio: [(url: URL, gain: Double)]) -> String {
        var stages: [String] = []
        var inputs: [String] = []

        for (index, track) in audio.enumerated() {
            let stream = "[\(index + 1):a]"
            guard abs(track.gain) >= 0.1 else {
                inputs.append(stream)
                continue
            }
            let label = "[g\(index)]"
            stages.append(stream + String(format: "volume=%.1fdB", track.gain) + label)
            inputs.append(label)
        }

        stages.append(
            inputs.joined() + "amix=inputs=\(audio.count):duration=longest:normalize=0[a]"
        )
        return stages.joined(separator: ";")
    }

    @discardableResult
    public static func mux(_ plan: OutputPlan) throws -> MuxOutcome {
        guard let ffmpeg = ffmpegPath() else { throw MuxError.ffmpegNotFound }
        let balance = balance(plan, using: ffmpeg)
        let (args, output) = try arguments(for: plan, gains: balance.gains)

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
        return MuxOutcome(output: output, notes: balance.notes)
    }

    /// Measuring costs one audio-only pass over each track; a mix that buries one
    /// side of the call costs the recording. Bleed is checked first: raising a
    /// microphone that already contains the call only doubles the echo.
    private static func balance(
        _ plan: OutputPlan, using ffmpeg: String
    ) -> (gains: TrackGains, notes: [String]) {
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        guard exists(plan.systemAudio), exists(plan.microphone) else { return (.none, []) }

        guard
            !SpeakerBleed.detected(
                systemAudio: plan.systemAudio, microphone: plan.microphone, using: ffmpeg
            )
        else { return (.none, [SpeakerBleed.warning]) }

        let gains = LoudnessMatch.gains(
            systemAudio: LoudnessMatch.measure(plan.systemAudio, using: ffmpeg),
            microphone: LoudnessMatch.measure(plan.microphone, using: ffmpeg)
        )
        return (gains, [])
    }
}
