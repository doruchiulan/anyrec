import Foundation
import Testing

@testable import AnyRecKit

@Suite("SpeechRegions")
struct SpeechRegionsTests {
    /// One frame is 20 ms, so a second of anything is fifty of them.
    private func envelope(_ blocks: [(level: Double, seconds: Double)]) -> AudioEnvelope {
        AudioEnvelope(
            frames: blocks.flatMap { block in
                Array(repeating: block.level, count: Int(block.seconds / 0.02))
            })
    }

    private let quiet = 0.01
    private let loud = 1.0

    @Test("finds the speech and leaves the room tone behind")
    func findsSpeech() {
        let regions = detect([(quiet, 5), (loud, 3), (quiet, 5)])

        #expect(regions.count == 1)
        /// Padded either side, because a word starts quieter than its middle.
        #expect(regions[0].lowerBound == 4.7)
        #expect(regions[0].upperBound == 8.3)
    }

    @Test("keeps a breath inside the sentence around it")
    func keepsShortPauses() {
        #expect(detect([(loud, 2), (quiet, 0.6), (loud, 2)]).count == 1)
    }

    @Test("breaks where the quiet outlasts a pause")
    func breaksOnSilence() {
        #expect(detect([(loud, 2), (quiet, 4), (loud, 2)]).count == 2)
    }

    @Test("ignores a click too short to hold a word")
    func ignoresBlips() {
        #expect(detect([(quiet, 5), (loud, 0.1), (quiet, 5)]).isEmpty)
    }

    @Test("hands back the whole of a track that never stops talking")
    func continuousSpeech() {
        let regions = detect([(loud, 10)])

        #expect(regions.count == 1)
        #expect(regions[0].lowerBound == 0)
    }

    @Test("finds nothing in silence rather than inventing a region")
    func silence() {
        #expect(SpeechRegions.detect(in: envelope([(0, 10)])).isEmpty)
        #expect(SpeechRegions.detect(in: AudioEnvelope(frames: [])).isEmpty)
    }

    private func detect(_ blocks: [(Double, Double)]) -> [Range<TimeInterval>] {
        SpeechRegions.detect(in: envelope(blocks.map { (level: $0.0, seconds: $0.1) }))
    }
}

@Suite("AudioEnvelope")
struct AudioEnvelopeTests {
    @Test("reads the mean level over a span, and nothing outside the recording")
    func level() {
        let envelope = AudioEnvelope(frames: [0, 0, 4, 4, 0])

        #expect(envelope.level(from: 0.04, to: 0.06) == 4)
        #expect(envelope.level(from: 10, to: 12) == 0)
    }

    @Test("takes the noise floor low enough that a pause cannot raise it")
    func noiseFloor() {
        let frames = Array(repeating: 0.1, count: 30) + Array(repeating: 9.0, count: 70)

        #expect(AudioEnvelope(frames: frames).noiseFloor == 0.1)
    }

    @Test("squares and roots a whole frame, and drops the partial one at the end")
    func rms() {
        let samples = Array(repeating: Int16(100), count: AudioEnvelope.frame + 40)

        #expect(AudioEnvelope.rms(of: samples) == [100])
    }
}
