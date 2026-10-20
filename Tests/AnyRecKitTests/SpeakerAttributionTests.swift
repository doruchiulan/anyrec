import Foundation
import Testing

@testable import AnyRecKit

@Suite("SpeakerAttribution")
struct SpeakerAttributionTests {
    /// Frames are 20 ms, so `level` over one second is fifty of them.
    private func track(_ seconds: [Double]) -> AudioEnvelope {
        AudioEnvelope(frames: seconds.flatMap { Array(repeating: $0, count: 50) })
    }

    private func line(_ start: TimeInterval, _ speaker: Speaker) -> Utterance {
        Utterance(start: start, end: start + 1, text: "said something", speaker: speaker)
    }

    @Test("gives a line to whichever track was louder while it was said")
    func louderWins() {
        let result = SpeakerAttribution.label(
            [line(0, .others), line(1, .others)],
            microphone: track([9, 0.1]), systemAudio: track([0.1, 9])
        )

        #expect(result.map(\.speaker) == [.me, .others])
    }

    @Test("leaves a line with the call when the two tracks are too close to separate")
    func ambiguous() {
        let result = SpeakerAttribution.label(
            [line(0, .others)], microphone: track([1.0]), systemAudio: track([0.9])
        )

        #expect(result[0].speaker == .others)
    }

    @Test("puts an echo back on the caller, because it is quieter than its source")
    func bleed() {
        /// The far end at full strength down the wire, and again through the room.
        let result = SpeakerAttribution.label(
            [line(0, .others)], microphone: track([2]), systemAudio: track([9])
        )

        #expect(result[0].speaker == .others)
    }

    @Test("leaves a room that is merely louder than a silent call with the call")
    func roomNoise() {
        /// A fan at 0.3, a chair creak at twice that, and one real line at 9.
        let result = SpeakerAttribution.label(
            [line(4, .others), line(5, .others)],
            microphone: track([0.3, 0.3, 0.3, 0.3, 0.6, 9]),
            systemAudio: track([0.1, 0.1, 0.1, 0.1, 0.1, 0.1])
        )

        #expect(result.map(\.speaker) == [.others, .me])
    }

    @Test("reads the microphone as the mix heard it when the call bleeds")
    func ducked() {
        /// A cue inside the far end's sentence, with the room running louder than the
        /// wire copy for its span — and your own line once the call falls quiet. In
        /// sample units, because the duck's threshold is ffmpeg's and absolute.
        let lines = [line(1, .others), line(2, .others)]
        let microphone = track([10, 1400, 900])
        let systemAudio = track([900, 900, 10])

        let plain = SpeakerAttribution.label(
            lines, microphone: microphone, systemAudio: systemAudio)
        let ducked = SpeakerAttribution.label(
            lines, microphone: microphone, systemAudio: systemAudio,
            mix: MixPlan(balance: .duckedMicrophone))

        #expect(plain.map(\.speaker) == [.me, .me])
        #expect(ducked.map(\.speaker) == [.others, .me])
    }

    @Test("never claims a line the call could not hear")
    func muted() {
        /// Two clear lines on the microphone; the call was only listening for the first.
        let live = MicrophoneLive(duration: 2, spans: [0..<1])

        let result = SpeakerAttribution.label(
            [line(0, .others), line(1, .others)],
            microphone: track([9, 9]), systemAudio: track([0.1, 0.1]),
            mix: MixPlan(balance: .matched(.none), microphoneLive: live)
        )

        #expect(result.map(\.speaker) == [.me, .others])
    }

    @Test("takes your lines out of a diarised set and letters the rest from the top")
    func picksMineFromVoices() {
        let result = SpeakerAttribution.label(
            [line(0, .voice("A")), line(1, .voice("B")), line(2, .voice("C"))],
            microphone: track([0.1, 9, 0.1]), systemAudio: track([9, 0.1, 9])
        )

        #expect(result.map(\.speaker) == [.voice("A"), .me, .voice("B")])
    }

    @Test("splits a voice the model fused out of you and the caller")
    func splitsFusedVoice() {
        let result = SpeakerAttribution.label(
            [line(0, .voice("A")), line(1, .voice("A")), line(2, .voice("A"))],
            microphone: track([9, 0.1, 0.1]), systemAudio: track([0.1, 9, 9])
        )

        #expect(result.map(\.speaker) == [.me, .voice("A"), .voice("A")])
    }

    @Test("gathers your lines under one name, however the model lettered them")
    func gathersMyLines() {
        let result = SpeakerAttribution.label(
            [line(0, .voice("A")), line(1, .voice("B"))],
            microphone: track([9, 5]), systemAudio: track([0.1, 0.1])
        )

        #expect(result.map(\.speaker) == [.me, .me])
    }

    @Test("cuts a segment the model gave one letter when the reply is inside it")
    func cutsFusedSegment() {
        let fused = Utterance(
            start: 0, end: 2, text: "Stau pe aici. Sunt bine.", speaker: .voice("A"))

        let result = SpeakerAttribution.label(
            [fused], microphone: track([9, 0.1]), systemAudio: track([0.1, 9])
        )

        #expect(result.map(\.speaker) == [.me, .voice("A")])
        #expect(result.map(\.text) == ["Stau pe aici.", "Sunt bine."])
    }

    @Test("leaves a segment whole when its sentences were said by the same person")
    func keepsAgreeingSegment() {
        let line = Utterance(
            start: 0, end: 2, text: "Stau pe aici. Sunt bine.", speaker: .voice("A"))

        let result = SpeakerAttribution.label(
            [line], microphone: track([9, 9]), systemAudio: track([0.1, 0.1])
        )

        #expect(result.count == 1)
        #expect(result[0].speaker == .me)
        #expect(result[0].text == "Stau pe aici. Sunt bine.")
    }

    @Test("leaves the labels alone when a track is missing")
    func noEnvelope() {
        let lines = [line(0, .others)]

        #expect(
            SpeakerAttribution.label(
                lines, microphone: AudioEnvelope(frames: []), systemAudio: track([9])
            ).map(\.speaker) == [.others])
    }
}
