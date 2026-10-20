import Testing

@testable import AnyRecKit

@Suite("MixPlan")
struct MixPlanTests {
    private let sum = "amix=inputs=2:duration=longest:normalize=0[a]"
    private let ducked = MixPlan(balance: .duckedMicrophone)

    @Test("sums the tracks as they are when nothing needs doing")
    func plain() {
        #expect(MixPlan.plain.filter(systemAudio: 1, microphone: 2) == "[1:a][2:a]" + sum)
        #expect(MixPlan.plain.notes.isEmpty)
    }

    @Test("sums inputs in ffmpeg's order, whichever track is named first")
    func inputOrder() {
        #expect(MixPlan.plain.filter(systemAudio: 1, microphone: 0) == "[0:a][1:a]" + sum)
    }

    @Test("gives each matched track its own volume stage, and none when it is flat")
    func matched() {
        let both = MixPlan(balance: .matched(TrackGains(systemAudio: -2, microphone: 6.4)))
        let flat = MixPlan(balance: .matched(TrackGains(systemAudio: 0, microphone: 5)))

        #expect(
            both.filter(systemAudio: 1, microphone: 2)
                == "[1:a]volume=-2.0dB[g1];[2:a]volume=6.4dB[g2];[g1][g2]" + sum)
        #expect(
            flat.filter(systemAudio: 1, microphone: 2) == "[2:a]volume=5.0dB[g2];[1:a][g2]" + sum)
    }

    @Test("keys the microphone off the call when the call is in it")
    func duckedMicrophone() {
        let graph = ducked.filter(systemAudio: 1, microphone: 0)

        #expect(
            graph == "[1:a]asplit[key][call];[0:a][key]\(MixPlan.duck)[mic];[call][mic]" + sum)
        #expect(ducked.notes == [SpeakerBleed.warning])
        #expect(MixPlan.duck == "sidechaincompress=threshold=0.002:ratio=20:attack=5:release=300")
    }

    @Test("silences the microphone wherever the call was not listening")
    func gated() {
        let live = MicrophoneLive(duration: 10, spans: [1..<2.5, 4..<10])
        let plan = MixPlan(balance: .matched(.none), microphoneLive: live)

        #expect(
            plan.filter(systemAudio: 1, microphone: 2)
                == "[2:a]volume=0:enable='not(between(t,1.00,2.50)+between(t,4.00,10.00))'[live]"
                + ";[1:a][live]" + sum)
    }

    @Test("silences the microphone throughout when the call never listened, under a duck too")
    func mutedThroughout() {
        let live = MicrophoneLive(duration: 10, spans: [])
        let plan = MixPlan(balance: .duckedMicrophone, microphoneLive: live)

        #expect(
            plan.filter(systemAudio: 1, microphone: 2)
                == "[2:a]volume=0[live];[1:a]asplit[key][call];[live][key]\(MixPlan.duck)[mic]"
                + ";[call][mic]" + sum)
        #expect(plan.notes.count == 2)
        #expect(plan.notes[1].hasPrefix("The call was not listening to the microphone for 0:10"))
    }
}
