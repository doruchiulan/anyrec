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

    @Test("takes off the louder track whatever headroom cannot absorb")
    func splitsAgainstTheCeiling() {
        let loud = Loudness(integrated: -20, truePeak: -6)
        let quiet = Loudness(integrated: -30, truePeak: -6)

        let gains = LoudnessMatch.gains(systemAudio: loud, microphone: quiet)

        #expect(abs(gains.microphone - 4) < 0.001)
        #expect(abs(gains.systemAudio + 6) < 0.001)
        #expect(abs(gains.microphone - gains.systemAudio - 10) < 0.001)
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

    @Test("reads loudness and true peak out of loudnorm's json")
    func parsesLoudnorm() {
        let log = """
            [Parsed_loudnorm_0 @ 0x600000] \n{
                    "input_i" : "-29.10",
                    "input_tp" : "-16.20",
                    "input_lra" : "9.20",
                    "normalization_type" : "dynamic"
            }
            """

        let loudness = LoudnessMatch.parse(log)

        #expect(loudness == Loudness(integrated: -29.1, truePeak: -16.2))
        #expect(LoudnessMatch.parse("no json here") == nil)
    }
}
