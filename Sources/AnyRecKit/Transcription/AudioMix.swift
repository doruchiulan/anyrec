import Foundation

/// The single file a transcription engine is handed.
///
/// Transcribed apart, the two tracks come back as two timelines, and an engine's
/// timestamps are only honest about its own audio — merging them shuffles the
/// conversation. Mixed, the engine orders the call itself; who said what is
/// recovered afterwards from the tracks, which are still on disk untouched.
public enum AudioMix {
    /// 16 kHz mono is what every engine here resamples to anyway.
    static let sampleRate = 16_000
    static let name = "mix.wav"

    /// Nil when there is nothing to mix, so the caller can transcribe the one track
    /// it has instead.
    public static func build(
        microphone: URL?, systemAudio: URL?, into directory: URL, using ffmpeg: String
    ) throws -> URL? {
        let sources = [microphone, systemAudio].compactMap { $0 }
        guard sources.count > 1 else { return nil }

        let output = directory.appendingPathComponent(name)
        var arguments = ["-nostdin", "-y", "-v", "error"]
        arguments += sources.flatMap { ["-i", $0.path] }
        arguments += [
            "-filter_complex", filter(microphone: microphone, systemAudio: systemAudio, using: ffmpeg),
            "-map", "[a]", "-ar", "\(sampleRate)", "-ac", "1", output.path,
        ]

        let result = try Shell.run(ffmpeg, arguments)
        guard result.succeeded else {
            throw TranscriptionError.engineFailed(engine: "ffmpeg", log: result.combined)
        }
        return output
    }

    /// The same loudness match the playable mix uses: summing raw would bury whoever
    /// is talking in a quiet room, and an engine cannot transcribe what it cannot hear.
    private static func filter(
        microphone: URL?, systemAudio: URL?, using ffmpeg: String
    ) -> String {
        guard let microphone, let systemAudio else { return "amix=inputs=2[a]" }
        let gains = LoudnessMatch.gains(
            systemAudio: LoudnessMatch.measure(systemAudio, using: ffmpeg),
            microphone: LoudnessMatch.measure(microphone, using: ffmpeg)
        )
        return stages([gains.microphone, gains.systemAudio])
    }

    /// One `volume` stage per track that needs one; a gain of zero adds no stage.
    static func stages(_ gains: [Double]) -> String {
        var built: [String] = []
        var inputs: [String] = []

        for (index, gain) in gains.enumerated() {
            let stream = "[\(index):a]"
            guard abs(gain) >= 0.1 else {
                inputs.append(stream)
                continue
            }
            built.append(stream + String(format: "volume=%.1fdB", gain) + "[g\(index)]")
            inputs.append("[g\(index)]")
        }

        built.append(
            inputs.joined() + "amix=inputs=\(gains.count):duration=longest:normalize=0[a]")
        return built.joined(separator: ";")
    }
}
