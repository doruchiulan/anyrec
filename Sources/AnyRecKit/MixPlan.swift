import Foundation

/// How the two audio tracks go together: decided once, from the tracks themselves
/// and what was watched while they were recorded, and built from by both mixes — the
/// merged, playable file and the file an engine transcribes — so the two cannot
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

    /// How far each track is moved so both sit on the raw microphone's timeline, which
    /// is also the video's and the call window's. Seconds earlier; negative is later.
    public struct Alignment: Sendable, Equatable, Codable {
        /// The system track, by the lag of the far end's echo behind it.
        public var systemAudio: TimeInterval
        /// The microphone the mix uses: zero for the raw track, the measured lag of the
        /// echo-cancelled one behind the raw one when that is used.
        public var microphone: TimeInterval

        public init(systemAudio: TimeInterval = 0, microphone: TimeInterval = 0) {
            self.systemAudio = systemAudio
            self.microphone = microphone
        }

        public static let none = Alignment()
    }

    /// Which microphone recording the mix is built from. The raw track is the master and
    /// always there; the echo-cancelled one is used when it was recorded and carries sound.
    public enum MicrophoneTrack: String, Sendable, Equatable, Codable {
        case raw, clean

        /// The file for this track beside the raw microphone `raw`.
        public func url(besideRaw raw: URL) -> URL {
            switch self {
            case .raw: raw
            case .clean: raw.deletingLastPathComponent().appendingPathComponent(OutputPlan.cleanMicrophoneName)
            }
        }
    }

    public var balance: Balance
    /// When the call could hear the microphone. Outside these spans it is silenced,
    /// because nothing on it reached anyone. Nil when nobody watched, and it is left
    /// alone.
    public var microphoneLive: MicrophoneLive?
    public var alignment: Alignment
    public var microphoneTrack: MicrophoneTrack

    public init(balance: Balance, microphoneLive: MicrophoneLive? = nil, alignment: Alignment = .none,
                microphoneTrack: MicrophoneTrack = .raw) {
        self.balance = balance
        self.microphoneLive = microphoneLive
        self.alignment = alignment
        self.microphoneTrack = microphoneTrack
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
    /// only doubles the echo. Tracks outside a recording folder are decided afresh;
    /// a recording's own are decided once, through `decided(for:using:)`.
    public static func decide(
        systemAudio: URL, microphone: URL, live: MicrophoneLive?, using ffmpeg: String
    ) -> MixPlan {
        let plan = OutputPlan(directory: microphone.deletingLastPathComponent())
        if plan.microphone == microphone.standardizedFileURL.resolvingSymlinksInPath(),
           plan.systemAudio == systemAudio.standardizedFileURL.resolvingSymlinksInPath() {
            var decided = decided(for: plan, using: ffmpeg)
            decided.microphoneLive = live
            return decided
        }
        let decision = decide(systemAudio: systemAudio, microphone: microphone, clean: nil,
                              basis: .init(microphone: nil, systemAudio: nil, microphoneLive: nil), using: ffmpeg)
        return decision.plan(live: live)
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
    /// into `[a]`. Each track is first moved onto the raw microphone's timeline; the
    /// microphone input is whichever `microphoneTrack` names.
    public func filter(systemAudio: Int, microphone: Int) -> String {
        var stages: [String] = []
        var system = "[\(systemAudio):a]"
        if let shift = Self.shift(alignment.systemAudio) {
            stages.append(system + shift + "[sys]")
            system = "[sys]"
        }
        var mic = "[\(microphone):a]"
        if let shift = Self.shift(alignment.microphone) {
            stages.append(mic + shift + "[mic0]")
            mic = "[mic0]"
        }
        if let live = microphoneLive {
            stages.append(mic + Self.gate(live) + "[live]")
            mic = "[live]"
        }

        switch balance {
        case .matched(let gains):
            stages += Self.matched([
                (systemAudio, system, gains.systemAudio),
                (microphone, mic, gains.microphone),
            ])
        case .duckedMicrophone:
            stages += [
                system + "asplit[key][call]",
                mic + "[key]" + Self.duck + "[mic]",
                "[call][mic]" + Self.sum(2),
            ]
        }
        return stages.joined(separator: ";")
    }

    /// The graph that leaves only the microphone as the mix hears it, in `[a]`: moved,
    /// gated, and held under the call when the plan ducks. What the echo check measures,
    /// so it hears exactly the duck the mixes apply.
    public func microphoneFilter(systemAudio: Int, microphone: Int) -> String {
        let whole = filter(systemAudio: systemAudio, microphone: microphone)
        switch balance {
        case .duckedMicrophone:
            return whole.replacingOccurrences(of: "[call][mic]" + Self.sum(2), with: "[call]anullsink;[mic]anull[a]")
        case .matched:
            var stages: [String] = []
            var mic = "[\(microphone):a]"
            if let shift = Self.shift(alignment.microphone) {
                stages.append(mic + shift + "[mic0]")
                mic = "[mic0]"
            }
            if let live = microphoneLive { stages.append(mic + Self.gate(live) + "[live]"); mic = "[live]" }
            stages.append(mic + "anull[a]")
            return stages.joined(separator: ";")
        }
    }

    /// A track moved `seconds` earlier (later when negative). Trimmed, it starts again at
    /// zero, so the gate's `t` and the sum read the microphone's timeline. Nothing under
    /// half a millisecond, which is less than a sample's worth of anything audible here.
    static func shift(_ seconds: TimeInterval) -> String? {
        guard abs(seconds) >= 0.0005 else { return nil }
        if seconds > 0 { return String(format: "atrim=start=%.4f,asetpts=PTS-STARTPTS", seconds) }
        return String(format: "adelay=delays=%.3f:all=1", -seconds * 1000)
    }

    /// The two envelopes as the mixes line them up: each track advanced by its offset, so
    /// both read on the raw microphone's timeline. Everything that compares the two —
    /// speech regions, attribution, the owner merge — reads them through this.
    public func aligned(systemAudio: AudioEnvelope, microphone: AudioEnvelope) -> (systemAudio: AudioEnvelope, microphone: AudioEnvelope) {
        (systemAudio.advanced(by: alignment.systemAudio), microphone.advanced(by: alignment.microphone))
    }

    /// How long a track of `length` seconds runs once moved.
    public func length(of length: TimeInterval, systemAudio: Bool) -> TimeInterval {
        max(0, length - (systemAudio ? alignment.systemAudio : alignment.microphone))
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
