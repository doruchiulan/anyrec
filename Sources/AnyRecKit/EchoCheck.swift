import Foundation

/// How much of the far end is left in the microphone, measured three ways on one recording:
/// the raw track, the duck as it was before the tracks were lined up, and the duck lined up.
/// What tells after a call on speakers whether the echo handling is doing its job.
///
/// It also compared an echo-cancelled microphone recorded at capture with macOS voice
/// processing, until that was removed (0.7.2): its track came out silent, and while it ran
/// macOS turned the microphone down 25 to 30 dB for every app, the call included.
///
/// "Echo left" is the microphone's level against the far end's at the moments the far end
/// was talking, in dB, with the far end read off the system track moved onto the
/// microphone's timeline. Lower is better; the room alone is about −30 dB here, the lined-up
/// duck about −45. The owner's level is read where only the owner talks.
public struct EchoReport: Sendable {
    public struct Echo: Sendable, Equatable {
        /// Median dB under the far end, over the frames the far end talks in.
        public let median: Double
        /// Share of those frames less than 20 dB under the far end: audible echo.
        public let audible: Double
        /// Share of frames in the first half-second of each far-end phrase less than
        /// 12 dB under it: the leak a late duck lets through.
        public let onsetLoud: Double
        public let phrases: Int
    }

    public let systemAudioOffset: TrackOffset?
    /// Nil when that track or measurement is not there.
    public let raw: Echo?
    public let duckedBefore: Echo?
    public let duckedAligned: Echo?
    /// The owner's median level, dBFS, where only they talk.
    public let ownerRaw: Double?
    public let timing: CaptureTiming?

    /// No echo to measure from: headphones, or a far end that never came back through the
    /// microphone.
    public var noEcho: Bool { duckedAligned == nil || systemAudioOffset?.isMeasured != true }
}

public enum EchoCheck {
    public static func measure(_ plan: OutputPlan, using ffmpeg: String) throws -> EchoReport {
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        guard exists(plan.systemAudio), exists(plan.microphone) else { throw MuxError.nothingToMerge }
        let live = MicrophoneLive.read(plan.microphoneLive)
        let decision = MixPlan.decide(systemAudio: plan.systemAudio, microphone: plan.microphone, live: live,
                                      basis: .of(plan), boundaries: MixPlan.boundaries(in: plan.directory), using: ffmpeg)
        let envelopes = AudioEnvelope.of([plan.systemAudio, plan.microphone], using: ffmpeg)
        guard let system = envelopes[0], let raw = envelopes[1] else { throw MuxError.unreadable(plan.microphone, "it could not be decoded") }

        let systemShift = decision.systemAudioOffset?.shift ?? .zero
        let far = system.advanced(by: systemShift)
        let measuredEcho = decision.systemAudioOffset?.isMeasured == true
        let talking = farTalking(far)

        let duck = { (alignment: MixPlan.Alignment) -> AudioEnvelope? in
            let mix = MixPlan(balance: .duckedMicrophone, microphoneLive: nil, alignment: alignment)
            return ducked(systemAudio: plan.systemAudio, microphone: plan.microphone, plan: mix, using: ffmpeg)
        }
        let before = duck(.none)
        let aligned = duck(MixPlan.Alignment(systemAudio: systemShift))

        let alone = ownerAlone(raw: raw, far: far, live: live)
        let echo = { (track: AudioEnvelope?) in track.flatMap { echoLeft($0, far: far, talking: talking) } }
        return EchoReport(
            systemAudioOffset: decision.systemAudioOffset,
            raw: echo(raw), duckedBefore: echo(before), duckedAligned: measuredEcho ? echo(aligned) : nil,
            ownerRaw: level(raw, at: alone), timing: RecordingInfo.read(plan.directory)?.timing)
    }

    /// The microphone as a ducking mix hears it, through the same filter graph the mixes
    /// use. Nil when ffmpeg could not make it.
    static func ducked(systemAudio: URL, microphone: URL, plan: MixPlan, using ffmpeg: String) -> AudioEnvelope? {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-echo-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let arguments = [
            "-nostdin", "-y", "-v", "error", "-i", systemAudio.path, "-i", microphone.path,
            "-filter_complex", plan.microphoneFilter(systemAudio: 0, microphone: 1),
            "-map", "[a]", "-ac", "1", "-ar", "\(AudioEnvelope.sampleRate)", scratch.path,
        ]
        guard let result = try? Shell.run(ffmpeg, arguments), result.succeeded else { return nil }
        return AudioEnvelope.of(scratch, using: ffmpeg)
    }

    /// The far end talking: above its own speech line and above the 60th percentile, so a
    /// call that is mostly silence is not judged on its comfort noise.
    static func farTalking(_ far: AudioEnvelope) -> [Bool] {
        guard !far.isEmpty else { return [] }
        let sorted = far.frames.sorted()
        let line = max(SpeechRegions.threshold(for: far), sorted[Int(Double(sorted.count) * 0.6)])
        return far.frames.map { $0 > line && $0 > 0 }
    }

    static func echoLeft(_ track: AudioEnvelope, far: AudioEnvelope, talking: [Bool]) -> EchoReport.Echo? {
        let count = min(track.frames.count, far.frames.count, talking.count)
        let decibels = { (value: Double) in 20 * log10(max(value, 1e-3)) }
        var relative: [Double] = []
        var onset: [Double] = []
        var phrases = 0
        let onsetFrames = AudioEnvelope.index(at: 0.5)
        var phraseStart = 0
        for index in 0..<count where talking[index] {
            if index == 0 || !talking[index - 1] {
                phraseStart = index
                phrases += 1
            }
            let difference = decibels(track.frames[index]) - decibels(far.frames[index])
            relative.append(difference)
            if index - phraseStart < onsetFrames { onset.append(difference) }
        }
        guard !relative.isEmpty else { return nil }
        return EchoReport.Echo(
            median: TrackAlignment.median(relative),
            audible: Double(relative.filter { $0 > -20 }.count) / Double(relative.count),
            onsetLoud: onset.isEmpty ? 0 : Double(onset.filter { $0 > -12 }.count) / Double(onset.count),
            phrases: phrases)
    }

    /// Frames where the owner talks and the far end does not, while the call could hear them.
    static func ownerAlone(raw: AudioEnvelope, far: AudioEnvelope, live: MicrophoneLive?) -> [Int] {
        let speaking = SpeechRegions.threshold(for: raw)
        let quiet = far.noiseFloor * SpeechRegions.overFloor
        let count = min(raw.frames.count, far.frames.count)
        return (0..<count).filter { index in
            guard raw.frames[index] > speaking, far.frames[index] <= quiet else { return false }
            guard let live else { return true }
            let time = AudioEnvelope.time(of: index)
            return live.spans.contains { $0.contains(time) }
        }
    }

    /// Median dBFS over the given frames.
    static func level(_ track: AudioEnvelope, at frames: [Int]) -> Double? {
        let values = frames.filter { $0 < track.frames.count }.map { 20 * log10(max(track.frames[$0], 1e-3) / Double(Int16.max)) }
        return values.isEmpty ? nil : TrackAlignment.median(values)
    }
}
