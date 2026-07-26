import Foundation
import Testing

@testable import SlackRecKit

@Suite("MeterScale")
struct MeterScaleTests {
    @Test(
        "maps dBFS onto the bar",
        arguments: [
            (Float(0), 20),
            (-30, 10),
            (-60, 0),
            (-120, 0),
        ]
    )
    func fill(dBFS: Float, expected: Int) {
        #expect(MeterScale.filled(dBFS, width: 20) == expected)
    }

    @Test("never overflows the bar it is given")
    func clamps() {
        #expect(MeterScale.filled(12, width: 20) == 20)
        #expect(MeterScale.filled(-10, width: 0) == 0)
    }

    @Test(
        "sorts levels into zones",
        arguments: [
            (Float(-120), MeterScale.Zone.silent),
            (-90, .silent),
            (-44, .faint),
            (-20, .healthy),
            (-0.5, .hot),
        ]
    )
    func zones(dBFS: Float, expected: MeterScale.Zone) {
        #expect(MeterScale.zone(dBFS) == expected)
    }

    @Test("only comments on tracks that need attention")
    func verdicts() {
        #expect(MeterScale.verdict(peak: -20, for: .microphone) == nil)
        #expect(MeterScale.verdict(peak: -100, for: .microphone) != nil)
        #expect(MeterScale.verdict(peak: -44, for: .microphone)?.contains("sources") == true)
        #expect(MeterScale.verdict(peak: -44, for: .systemAudio)?.contains("sources") == false)
    }

    @Test("prints silence as a placeholder rather than -120")
    func reading() {
        #expect(MeterScale.reading(AudioLevel.floor).trimmingCharacters(in: .whitespaces) == "--")
        #expect(MeterScale.reading(-12.34) == "-12.3")
    }
}

@Suite("AudioLevel")
struct AudioLevelTests {
    @Test("converts amplitude to dBFS, with a floor")
    func dBFS() {
        #expect(AudioLevelMeter.dBFS(1) == 0)
        #expect(abs(AudioLevelMeter.dBFS(0.5) - -6.02) < 0.01)
        #expect(AudioLevelMeter.dBFS(0) == AudioLevel.floor)
        #expect(AudioLevelMeter.dBFS(-1) == AudioLevel.floor)
    }

    @Test("classifies a track from its peak")
    func classification() {
        #expect(AudioLevel(peak: -95, rms: -110).isSilent)
        #expect(AudioLevel(peak: -44, rms: -64).isRoomTone)
        #expect(!AudioLevel(peak: -12, rms: -25).isRoomTone)
    }
}
