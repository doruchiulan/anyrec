import Foundation
import Testing

@testable import AnyRecKit

@Suite("Echo check")
struct EchoCheckTests {
    private func echo(_ median: Double, onset: Double = 0) -> EchoReport.Echo {
        EchoReport.Echo(median: median, audible: 0, onsetLoud: onset, phrases: 10)
    }

    private func report(clean: EchoReport.Echo?, aligned: EchoReport.Echo? = nil, measured: Bool = true,
                        ownerClean: Double? = -33, bleeds: Bool? = false) -> EchoReport {
        EchoReport(
            systemAudioOffset: TrackOffset(seconds: measured ? 0.5 : nil, confidence: 0.9, windowsUsed: 8, windowsTried: 8),
            cleanMicrophoneOffset: nil, raw: echo(1), duckedBefore: echo(-31, onset: 0.26),
            duckedAligned: aligned ?? echo(-35, onset: 0.01), clean: clean, cleanDucked: clean.map { echo($0.median - 5) },
            ownerRaw: -32, ownerClean: ownerClean, cleanStillBleeds: bleeds, timing: nil)
    }

    @Test("capture-time cancellation wins when it leaves no more echo than the lined-up duck and keeps the voice")
    func verdict() {
        #expect(report(clean: echo(-40)).verdict == .captureWins)
        #expect(report(clean: echo(-20)).verdict == .duckWins)
        #expect(report(clean: echo(-40, onset: 0.2)).verdict == .duckWins)
        /// Echo gone, and the owner with it.
        #expect(report(clean: echo(-40), ownerClean: -50).verdict == .duckWins)
        /// Still bleeding, so it is judged held down, as the mixes would use it.
        #expect(report(clean: echo(-32), bleeds: true).verdict == .captureWins)
        #expect(report(clean: nil).verdict == .noCleanTrack)
        #expect(report(clean: echo(-40), measured: false).verdict == .noEcho)
    }

    @Test("echo left is read where the far end talks, and phrase starts are their first half-second")
    func echoLeft() throws {
        let frames = 100
        let far = AudioEnvelope(frames: (0..<frames).map { (10..<45).contains($0) ? 1_000 : 1 })
        /// A duck that opens late: 10 dB under for the first 0.3 s of the phrase, 40 under after.
        let mic = AudioEnvelope(frames: (0..<frames).map { index in
            (10..<25).contains(index) ? 316 : (25..<45).contains(index) ? 10 : 1
        })
        let talking = EchoCheck.farTalking(far)
        #expect(talking.filter { $0 }.count == 35)
        let left = try #require(EchoCheck.echoLeft(mic, far: far, talking: talking))
        #expect(left.phrases == 1)
        #expect(abs(left.median + 40) < 0.1)
        #expect(abs(left.audible - 15.0 / 35) < 1e-9)
        #expect(abs(left.onsetLoud - 15.0 / 25) < 1e-9)
    }

    @Test("the owner is measured only where they talk alone and the call could hear them")
    func ownerAlone() {
        let raw = AudioEnvelope(frames: [5, 5, 800, 800, 800, 5, 5, 5, 5, 5])
        let far = AudioEnvelope(frames: [1, 1, 1, 900, 1, 1, 1, 1, 1, 1])
        #expect(EchoCheck.ownerAlone(raw: raw, far: far, live: nil) == [2, 4])
        let step = AudioEnvelope.frameDuration
        let live = MicrophoneLive(duration: 1, spans: [0..<(3 * step)])
        #expect(EchoCheck.ownerAlone(raw: raw, far: far, live: live) == [2])
    }
}
