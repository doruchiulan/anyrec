import Testing

@testable import AnyRecKit

@Suite("LoudnessMatch")
struct LoudnessMatchTests {
    /// The 22:31 recording: peaks 1.4 dB apart, loudness 13.4 dB apart.
    private let system = Loudness(integrated: -29.1, truePeak: -16.2)
    private let microphone = Loudness(integrated: -42.5, truePeak: -17.6)

    @Test("boosts the quieter track when it has the headroom for it")
    func boostsQuieter() {
        let gains = LoudnessMatch.gains(systemAudio: system, microphone: microphone)

        #expect(abs(gains.microphone - 13.4) < 0.001)
        #expect(gains.systemAudio == 0)
    }

    @Test("never lowers the louder track, even when the quieter one has no headroom: the mix limits it instead")
    func neverCutsTheLouder() {
        /// The headphone Teams call: the call went into the merge 29 dB down, at −46 LUFS.
        let call = Loudness(integrated: -18.1, truePeak: -0.3)
        let microphone = Loudness(integrated: -38.8, truePeak: -1.9)

        let gains = LoudnessMatch.gains(systemAudio: call, microphone: microphone)

        #expect(gains.systemAudio == 0)
        #expect(abs(gains.microphone - 20.7) < 0.001)
        #expect(LoudnessMatch.gains(systemAudio: microphone, microphone: call).microphone == 0)
    }

    @Test("raises the quieter track by at most 24 dB")
    func cappedBoost() {
        let gains = LoudnessMatch.gains(systemAudio: Loudness(integrated: -16, truePeak: -1),
                                        microphone: Loudness(integrated: -50, truePeak: -30))

        #expect(gains == TrackGains(systemAudio: 0, microphone: 24))
    }

    @Test("leaves a difference nobody would hear alone")
    func smallDifference() {
        let gains = LoudnessMatch.gains(
            systemAudio: Loudness(integrated: -24, truePeak: -8),
            microphone: Loudness(integrated: -26, truePeak: -8)
        )

        #expect(gains == .none)
    }

    @Test("never amplifies a silent track")
    func silentTrack() {
        let silent = Loudness(integrated: -70, truePeak: -91)

        #expect(LoudnessMatch.gains(systemAudio: silent, microphone: microphone) == .none)
        #expect(LoudnessMatch.gains(systemAudio: system, microphone: nil) == .none)
    }

    @Test("reads integrated loudness and true peak out of ebur128's summary")
    func parsesEBUR128() {
        let log = """
            [Parsed_ebur128_0 @ 0x600000] t: 12.3   TARGET:-23 LUFS    M: -30.1 S: -31.0     I: -40.2 LUFS
            [Parsed_ebur128_0 @ 0x600000] Summary:

              Integrated loudness:
                I:         -29.1 LUFS
                Threshold: -39.6 LUFS

              Loudness range:
                LRA:         9.2 LU
                Threshold:  -49.8 LUFS
                LRA low:   -35.4 LUFS
                LRA high:  -26.2 LUFS

              True peak:
                Peak:      -16.2 dBFS
            """

        #expect(LoudnessMatch.parse(log) == Loudness(integrated: -29.1, truePeak: -16.2))
        #expect(LoudnessMatch.parse("no summary here") == nil)
        let silent = log.replacingOccurrences(of: "-29.1 LUFS", with: "-70.0 LUFS")
            .replacingOccurrences(of: "-16.2 dBFS", with: "-inf dBFS")
        #expect(LoudnessMatch.parse(silent)?.isSilent == true)
        #expect(LoudnessMatch.parse(silent)?.truePeak == -.infinity)
    }
}
