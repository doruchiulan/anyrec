import Foundation

/// How the two audio tracks go together: decided once, from the tracks themselves
/// and what was watched while they were recorded, and built from by both mixes — the
/// playable `call.mp4` and the file an engine transcribes — so the two cannot
/// disagree about what the microphone is worth.
public struct MixPlan: Sendable, Equatable {
    public enum Balance: Sendable, Equatable {
        /// Each track rides in under its own gain, so neither side buries the other.
        case matched(TrackGains)
        /// The call is in the microphone too, so the microphone is held down whenever
        /// the call speaks and let through when it falls quiet. Every word survives
        /// once; anything said over the other side does not.
        case duckedMicrophone
    }

    public var balance: Balance
    /// When the call could hear the microphone. Outside these spans it is silenced,
    /// because nothing on it reached anyone. Nil when nobody watched, and it is left
    /// alone.
    public var microphoneLive: MicrophoneLive?

    public init(balance: Balance, microphoneLive: MicrophoneLive? = nil) {
        self.balance = balance
        self.microphoneLive = microphoneLive
    }

    public static let plain = MixPlan(balance: .matched(.none))

    /// What a reader of the result has to know. Empty when nothing is wrong.
    public var notes: [String] {
        var notes: [String] = []
        if balance == .duckedMicrophone { notes.append(SpeakerBleed.warning) }
        if let note = microphoneLive?.note { notes.append(note) }
        return notes
    }

    /// Measuring costs an audio-only pass over each track; a mix that buries one side
    /// of the call costs the recording. Bleed is checked first: a microphone that
    /// already contains the call has no loudness of its own to match, and raising it
    /// only doubles the echo.
    public static func decide(
        systemAudio: URL, microphone: URL, live: MicrophoneLive?, using ffmpeg: String
    ) -> MixPlan {
        let bleeding = SpeakerBleed.detected(
            systemAudio: systemAudio, microphone: microphone, using: ffmpeg)
        let balance: Balance =
            bleeding
            ? .duckedMicrophone
            : .matched(
                LoudnessMatch.gains(
                    systemAudio: LoudnessMatch.measure(systemAudio, using: ffmpeg),
                    microphone: LoudnessMatch.measure(microphone, using: ffmpeg)
                ))
        return MixPlan(balance: balance, microphoneLive: live)
    }

    /// A sidechain compressor keyed on the call, which needs no estimate of how loud
    /// the echo is or how late it arrives. Measured on a speakerphone recording: the
    /// microphone falls 39 dB under the far end and is untouched where the call is
    /// silent. Attribution replays the same duck on the envelopes, so the two read
    /// from one pair of numbers.
    static let duck =
        "sidechaincompress=threshold=\(duckThreshold):ratio=20:attack=5"
        + ":release=\(Int((duckRelease * 1000).rounded()))"
    /// Linear, full scale. Just above a call's comfort noise, so only speech pulls
    /// the microphone down.
    static let duckThreshold = 0.002
    /// Outlasts a room, so the tail of a word goes with the word.
    static let duckRelease: TimeInterval = 0.3

    /// The `filter_complex` graph summing ffmpeg inputs `systemAudio` and `microphone`
    /// into `[a]`.
    public func filter(systemAudio: Int, microphone: Int) -> String {
        var stages: [String] = []
        var mic = "[\(microphone):a]"
        if let live = microphoneLive {
            stages.append(mic + Self.gate(live) + "[live]")
            mic = "[live]"
        }

        switch balance {
        case .matched(let gains):
            stages += Self.matched([
                (systemAudio, "[\(systemAudio):a]", gains.systemAudio),
                (microphone, mic, gains.microphone),
            ])
        case .duckedMicrophone:
            stages += [
                "[\(systemAudio):a]asplit[key][call]",
                mic + "[key]" + Self.duck + "[mic]",
                "[call][mic]" + Self.sum(2),
            ]
        }
        return stages.joined(separator: ";")
    }

    /// Silence wherever the call was not listening. `enable` is evaluated per frame
    /// against `t`; with no live span at all the microphone is silent throughout.
    static func gate(_ live: MicrophoneLive) -> String {
        guard !live.spans.isEmpty else { return "volume=0" }
        let spans = live.spans.map {
            String(format: "between(t,%.2f,%.2f)", $0.lowerBound, $0.upperBound)
        }
        return "volume=0:enable='not(" + spans.joined(separator: "+") + ")'"
    }

    /// Each gain rides in as its own `volume` stage; a gain of zero adds no stage at
    /// all. Inputs are summed in the order ffmpeg was given them.
    private static func matched(
        _ tracks: [(input: Int, stream: String, gain: Double)]
    ) -> [String] {
        var stages: [String] = []
        var inputs: [String] = []

        for track in tracks.sorted(by: { $0.input < $1.input }) {
            guard abs(track.gain) >= 0.1 else {
                inputs.append(track.stream)
                continue
            }
            let label = "[g\(track.input)]"
            stages.append(track.stream + String(format: "volume=%.1fdB", track.gain) + label)
            inputs.append(label)
        }

        stages.append(inputs.joined() + sum(tracks.count))
        return stages
    }

    private static func sum(_ count: Int) -> String {
        "amix=inputs=\(count):duration=longest:normalize=0[a]"
    }
}
