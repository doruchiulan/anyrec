import Foundation

/// The mix decided once per recording and kept beside the tracks as `mix.json`, so the
/// playable merge, the transcript's mix and every regeneration read one answer instead of
/// each measuring the tracks again. Derived, like `waveform.json`: delete it and it is
/// made again, and it is made again whenever a track or `microphone-live.json` changes.
public struct MixDecision: Codable, Equatable, Sendable {
    /// What a decision was made from: each input's size and modification time. A file
    /// that is absent is recorded as absent, so one appearing later is a change too.
    public struct Basis: Codable, Equatable, Sendable {
        public struct File: Codable, Equatable, Sendable {
            public let size: Int
            public let modified: Double
        }
        public let microphone: File?
        public let systemAudio: File?
        public let microphoneLive: File?
        /// The echo-cancelled microphone, `microphone-clean.m4a`.
        public var cleanMicrophone: File?

        public init(microphone: File?, systemAudio: File?, microphoneLive: File?, cleanMicrophone: File? = nil) {
            self.microphone = microphone
            self.systemAudio = systemAudio
            self.microphoneLive = microphoneLive
            self.cleanMicrophone = cleanMicrophone
        }

        public static func of(_ plan: OutputPlan) -> Basis {
            Basis(microphone: file(plan.microphone), systemAudio: file(plan.systemAudio),
                  microphoneLive: file(plan.microphoneLive), cleanMicrophone: file(plan.cleanMicrophone))
        }

        static func file(_ url: URL) -> File? {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }
            return File(size: size, modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
    }

    public static let fileName = "mix.json"
    /// 2 added the track alignment and the echo-cancelled microphone; a version-1 file is
    /// decided again, which is how an existing recording gets lined up.
    static let version = 2

    public var version = MixDecision.version
    public let basis: Basis
    /// The far end came back through the microphone the mix uses.
    public let bleeding: Bool
    /// What the meter read. Nil when bleeding, because a bleeding microphone is never
    /// measured, or when a track could not be read.
    public let microphoneLoudness: Loudness?
    public let systemAudioLoudness: Loudness?
    /// The system track's lag behind the raw microphone, measured from the far end's echo.
    /// Nil when either track could not be read.
    public var systemAudioOffset: TrackOffset?
    /// The echo-cancelled microphone's lag behind the raw one, measured from the owner's
    /// voice, which both carry. Nil when there is no clean track.
    public var cleanMicrophoneOffset: TrackOffset?
    /// Which microphone the mixes and attribution use.
    public var microphoneTrack: MixPlan.MicrophoneTrack

    public init(basis: Basis, bleeding: Bool, microphoneLoudness: Loudness?, systemAudioLoudness: Loudness?,
                systemAudioOffset: TrackOffset? = nil, cleanMicrophoneOffset: TrackOffset? = nil,
                microphoneTrack: MixPlan.MicrophoneTrack = .raw) {
        self.basis = basis
        self.bleeding = bleeding
        self.microphoneLoudness = microphoneLoudness
        self.systemAudioLoudness = systemAudioLoudness
        self.systemAudioOffset = systemAudioOffset
        self.cleanMicrophoneOffset = cleanMicrophoneOffset
        self.microphoneTrack = microphoneTrack
    }

    public var balance: MixPlan.Balance {
        bleeding ? .duckedMicrophone
            : .matched(LoudnessMatch.gains(systemAudio: systemAudioLoudness, microphone: microphoneLoudness))
    }

    /// What each track is moved by: a measured offset, else nothing. The clean
    /// microphone moves only when it is the one used.
    public var alignment: MixPlan.Alignment {
        MixPlan.Alignment(
            systemAudio: systemAudioOffset?.seconds ?? 0,
            microphone: microphoneTrack == .clean ? cleanMicrophoneOffset?.seconds ?? 0 : 0)
    }

    func plan(live: MicrophoneLive?) -> MixPlan {
        MixPlan(balance: balance, microphoneLive: live, alignment: alignment, microphoneTrack: microphoneTrack)
    }

    public static func read(in directory: URL) -> MixDecision? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let decision = try? JSONDecoder().decode(MixDecision.self, from: data),
              decision.version == version else { return nil }
        return decision
    }

    func write(in directory: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

extension MixPlan {
    /// The plan for a recording's two tracks, from `mix.json` when it still describes them
    /// and measured (then written) when it does not. Bleed is read off the envelopes, which
    /// are shared with attribution and speech detection rather than decoded again; loudness
    /// is measured only for a microphone that does not bleed. Both tracks are measured at
    /// once. Plain when either track is missing.
    public static func decided(for plan: OutputPlan, using ffmpeg: String) -> MixPlan {
        let live = MicrophoneLive.read(plan.microphoneLive)
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        guard exists(plan.systemAudio), exists(plan.microphone) else { return MixPlan(balance: .matched(.none), microphoneLive: live) }
        let basis = MixDecision.Basis.of(plan)
        if let cached = MixDecision.read(in: plan.directory), cached.basis == basis {
            return cached.plan(live: live)
        }
        let clean = exists(plan.cleanMicrophone) ? plan.cleanMicrophone : nil
        let decision = decide(systemAudio: plan.systemAudio, microphone: plan.microphone, clean: clean,
                              basis: basis, using: ffmpeg)
        decision.write(in: plan.directory)
        return decision.plan(live: live)
    }

    /// Lines the tracks up first — the system track against the raw microphone, from the
    /// far end's echo; the clean microphone against the raw one, from the owner's voice —
    /// then picks the microphone, then checks it for bleed on the aligned envelopes, then
    /// measures loudness only if it does not bleed.
    static func decide(systemAudio: URL, microphone: URL, clean: URL?, basis: MixDecision.Basis,
                       using ffmpeg: String) -> MixDecision {
        let envelopes = AudioEnvelope.of([systemAudio, microphone] + (clean.map { [$0] } ?? []), using: ffmpeg)
        let (system, raw) = (envelopes[0], envelopes[1])
        let cleaned = clean == nil ? nil : envelopes[2]
        let systemOffset = system.flatMap { s in raw.map { TrackAlignment.measure(reference: $0, other: s) } }
        let cleanOffset = cleaned.flatMap { c in raw.map { TrackAlignment.measure(reference: $0, other: c) } }
        let track: MicrophoneTrack = CleanMicrophone.usable(cleaned, besideRaw: raw) ? .clean : .raw

        var decision = MixDecision(basis: basis, bleeding: false, microphoneLoudness: nil, systemAudioLoudness: nil,
                                   systemAudioOffset: systemOffset, cleanMicrophoneOffset: cleanOffset,
                                   microphoneTrack: track)
        let chosen = track == .clean ? cleaned : raw
        let bleeding: Bool
        if let system, let chosen {
            let lined = decision.plan(live: nil).aligned(systemAudio: system, microphone: chosen)
            bleeding = SpeakerBleed.detected(systemAudio: lined.systemAudio, microphone: lined.microphone)
        } else {
            bleeding = false
        }
        guard !bleeding else {
            return MixDecision(basis: basis, bleeding: true, microphoneLoudness: nil, systemAudioLoudness: nil,
                               systemAudioOffset: systemOffset, cleanMicrophoneOffset: cleanOffset, microphoneTrack: track)
        }
        var loudness = [Loudness?](repeating: nil, count: 2)
        let tracks = [systemAudio, track.url(besideRaw: microphone)]
        loudness.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                slots[index] = LoudnessMatch.measure(tracks[index], using: ffmpeg)
            }
        }
        decision = MixDecision(basis: basis, bleeding: false, microphoneLoudness: loudness[1], systemAudioLoudness: loudness[0],
                               systemAudioOffset: systemOffset, cleanMicrophoneOffset: cleanOffset, microphoneTrack: track)
        return decision
    }

    /// The loudness of the mix this plan builds, worked out from the two track envelopes
    /// instead of decoding the mix: the gains and the gate and duck replayed on each, then
    /// summed as power, which is how two unrelated signals add. What speech detection reads.
    /// The envelopes are the aligned ones (`aligned(systemAudio:microphone:)`), of the
    /// microphone `microphoneTrack` names.
    public func envelope(systemAudio: AudioEnvelope, microphone: AudioEnvelope) -> AudioEnvelope {
        var mic = microphone
        var gains = TrackGains.none
        switch balance {
        case .matched(let matched): gains = matched
        case .duckedMicrophone:
            mic = mic.held(under: systemAudio, threshold: Self.duckThreshold * Double(Int16.max),
                           release: Self.duckRelease)
        }
        if let live = microphoneLive { mic = mic.only(during: live.spans) }
        let system = pow(10, gains.systemAudio / 20), microphoneGain = pow(10, gains.microphone / 20)
        let count = max(systemAudio.frames.count, mic.frames.count)
        return AudioEnvelope(frames: (0..<count).map { index in
            let s = index < systemAudio.frames.count ? systemAudio.frames[index] * system : 0
            let m = index < mic.frames.count ? mic.frames[index] * microphoneGain : 0
            return (s * s + m * m).squareRoot()
        })
    }
}
