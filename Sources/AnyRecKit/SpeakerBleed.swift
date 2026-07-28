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
        + "call.mp4 and hollows out. The separate tracks are unaffected, and the "
        + "transcript is too — an echo is quieter than what caused it, so it still "
        + "lands under the caller. Headphones are the only fix for the audio."

    /// Measured at +8.2 dB and +5.8 dB on two speakerphone recordings; headphones put
    /// it well below zero. Three leaves room for people talking over each other.
    static let threshold = 3.0
    /// The call counts as speaking above this share of its own loudest frame.
    static let speechShare = 0.15
    /// Fewer frames than this on either side and there is nothing to compare.
    static let minimumFrames = 25

    public static func detected(systemAudio: URL, microphone: URL, using ffmpeg: String) -> Bool {
        guard let system = AudioEnvelope.of(systemAudio, using: ffmpeg),
            let mic = AudioEnvelope.of(microphone, using: ffmpeg)
        else { return false }
        return detected(systemAudio: system, microphone: mic)
    }

    public static func detected(systemAudio: AudioEnvelope, microphone: AudioEnvelope) -> Bool {
        excess(systemAudio.frames, microphone.frames) >= threshold
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
}
