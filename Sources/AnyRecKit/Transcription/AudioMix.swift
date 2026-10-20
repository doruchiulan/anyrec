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

    /// The file, plus how the tracks went into it. Nil when there is nothing to mix,
    /// so the caller can transcribe the one track it has instead.
    public static func build(
        microphone: URL?, systemAudio: URL?, live: MicrophoneLive?, into directory: URL,
        using ffmpeg: String
    ) throws -> (url: URL, plan: MixPlan)? {
        guard let microphone, let systemAudio else { return nil }

        /// The same decision the playable mix makes. Summing raw buries whoever is
        /// talking in a quiet room, and summing a bleeding microphone hands the engine
        /// every word twice — which it transcribes twice, under two speakers.
        let plan = MixPlan.decide(
            systemAudio: systemAudio, microphone: microphone, live: live, using: ffmpeg)
        let output = directory.appendingPathComponent(name)
        let arguments = [
            "-nostdin", "-y", "-v", "error", "-i", microphone.path, "-i", systemAudio.path,
            "-filter_complex", plan.filter(systemAudio: 1, microphone: 0),
            "-map", "[a]", "-ar", "\(sampleRate)", "-ac", "1", output.path,
        ]

        let result = try Shell.run(ffmpeg, arguments)
        guard result.succeeded else {
            throw TranscriptionError.engineFailed(engine: "ffmpeg", log: result.combined)
        }
        return (output, plan)
    }
}
