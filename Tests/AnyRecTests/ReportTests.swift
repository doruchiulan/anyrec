import Foundation
import Testing

@testable import AnyRecKit
@testable import anyrec

@Suite("Report")
struct ReportTests {
    private func summary(endedEarly: String?) -> RecordingSummary {
        RecordingSummary(
            plan: OutputPlan(directory: URL(fileURLWithPath: "/tmp/call")),
            screenFrames: 100, systemAudioSamples: 50, microphoneSamples: 50,
            droppedSamples: 0, systemAudioPeak: -12, microphonePeak: -18,
            endedEarly: endedEarly
        )
    }

    @Test("says why a recording ended by itself, above everything else it has to say")
    func endedEarly() {
        let text = Report.render(summary(endedEarly: "The window being recorded closed."))

        #expect(text.contains("The window being recorded closed."))
    }

    @Test("says nothing about the ending when the recording was stopped normally")
    func stoppedNormally() {
        #expect(!Report.render(summary(endedEarly: nil)).contains("closed"))
    }
}
