import Foundation

/// Finds the far end's voice arriving twice: once cleanly on the system-audio track,
/// once a few milliseconds later through the speakers and back into the microphone.
///
/// Summing two near-identical copies comb-filters the result, and no filter can
/// separate them afterwards — so the only thing to do is stop amplifying the echo
/// and say what is wrong. Headphones are the actual fix.
public enum SpeakerBleed {
    public static let warning =
        "The microphone is picking up the speakers, so the call arrives twice in "
        + "call.mp4 and hollows out — and lands in the transcript twice too. The "
        + "separate tracks are unaffected. Headphones are the only fix."

    /// Attribution is the worse casualty: a line under the wrong name reads as fact,
    /// where hollow audio at least sounds wrong.
    public static let transcriptWarning =
        "The microphone picked up the speakers, so the far end was recorded twice and "
        + "appears under Me as well as under Call. Which of the Me lines are really "
        + "yours cannot be recovered from the audio — Call is the side to trust. "
        + "Headphones prevent it."

    /// Measured at +8.2 dB and +5.8 dB on two speakerphone recordings; headphones put
    /// it well below zero. Three leaves room for people talking over each other.
    static let threshold = 3.0
    /// 20 ms envelope frames, at which resolution the acoustic delay is invisible —
    /// the echo lands inside the same frame as the sound that caused it.
    static let frame = 160
    static let sampleRate = 8000
    /// The call counts as speaking above this share of its own loudest frame.
    static let speechShare = 0.15
    /// Fewer frames than this on either side and there is nothing to compare.
    static let minimumFrames = 25

    public static func detected(systemAudio: URL, microphone: URL, using ffmpeg: String) -> Bool {
        guard let system = envelope(of: systemAudio, using: ffmpeg),
            let mic = envelope(of: microphone, using: ffmpeg)
        else { return false }
        return excess(system, mic) >= threshold
    }

    /// How much louder the microphone runs while the call is speaking than while it is
    /// not. Turn-taking drives this negative — people fall quiet while the other talks
    /// — so only the far end coming back through the speakers can push it up.
    static func excess(_ system: [Double], _ mic: [Double]) -> Double {
        let count = min(system.count, mic.count)
        guard let peak = system[..<count].max(), peak > 0 else { return 0 }

        var speaking: [Double] = []
        var silent: [Double] = []
        for index in 0..<count {
            if system[index] > peak * speechShare {
                speaking.append(mic[index])
            } else {
                silent.append(mic[index])
            }
        }

        guard speaking.count >= minimumFrames, silent.count >= minimumFrames else { return 0 }
        let mean = { (frames: [Double]) in frames.reduce(0, +) / Double(frames.count) }
        let (hot, cold) = (mean(speaking), mean(silent))
        guard hot > 0, cold > 0 else { return 0 }
        return 20 * log10(hot / cold)
    }

    /// Loudness over time, which is what an echo shares with its source. Waveforms do
    /// not survive a room; the shape of who-is-talking-when does.
    private static func envelope(of url: URL, using ffmpeg: String) -> [Double]? {
        guard let samples = decode(url, using: ffmpeg) else { return nil }
        return stride(from: 0, to: samples.count - frame, by: frame).map { start in
            let window = samples[start..<(start + frame)]
            return (window.map { Double($0) * Double($0) }.reduce(0, +) / Double(frame)).squareRoot()
        }
    }

    private static func decode(_ url: URL, using ffmpeg: String) -> [Int16]? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("slack-rec-bleed-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let arguments = [
            "-nostdin", "-v", "error", "-i", url.path,
            "-ac", "1", "-ar", "\(sampleRate)", "-f", "s16le", scratch.path,
        ]
        guard let result = try? Shell.run(ffmpeg, arguments), result.succeeded,
            let data = try? Data(contentsOf: scratch)
        else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
}
