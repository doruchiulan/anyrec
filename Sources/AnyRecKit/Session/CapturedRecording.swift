import Foundation

public struct CapturedRecording: Sendable {
    public let summary: RecordingSummary
    public let microphoneLive: MicrophoneLive?

    public init(summary: RecordingSummary, microphoneLive: MicrophoneLive? = nil) {
        self.summary = summary
        self.microphoneLive = microphoneLive
    }

    public func merged(enabled: Bool) async -> RecordingOutcome {
        let merge: MergeOutcome
        if !enabled {
            merge = .notRequested
        } else if !Readiness.ffmpegInstalled {
            merge = .ffmpegMissing
        } else {
            do { merge = .merged(try Muxer.mux(summary.plan)) }
            catch { merge = .failed("\(error)") }
        }
        return RecordingOutcome(summary: summary, merge: merge, microphoneLive: microphoneLive)
    }
}
