import Foundation

/// A one-off check of how far apart ScreenCaptureKit stamps the call's audio and the
/// microphone on this Mac's current devices, without a call: a test signal is played out of
/// the speakers while a recording runs, and the offset is read from it in the two tracks the
/// same way it is read from a call's echo. What it needs is the speakers on and audible to
/// the microphone; what it leaves is a recording folder with its timing facts.
public enum TimingCheck {
    /// Seconds of signal: long enough for one alignment window with room either side.
    public static let duration: TimeInterval = 30

    /// Bursts of noise at irregular times, so only one lag lines the two tracks up.
    public static func signal(into url: URL, using ffmpeg: String) throws {
        let source = "anoisesrc=color=pink:amplitude=0.4:duration=\(Int(duration)):sample_rate=48000:seed=11,"
            + "volume='if(gt(sin(2*PI*t*0.53)+sin(2*PI*t*1.31)+sin(2*PI*t*2.17),1.2),1,0)':eval=frame"
        let result = try Shell.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", source, url.path])
        guard result.succeeded else { throw MuxError.failed(status: 1, log: result.combined) }
    }

    public struct Result: Sendable {
        /// The call track's lag behind the raw microphone.
        public let systemAudio: TrackOffset?
        /// The echo-cancelled microphone's lag behind the raw one, when it was recorded.
        public let cleanMicrophone: TrackOffset?
        public let timing: CaptureTiming?
    }

    /// Reads the offsets off a finished check's tracks.
    public static func measure(_ plan: OutputPlan, using ffmpeg: String) -> Result {
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        let clean = exists(plan.cleanMicrophone) ? plan.cleanMicrophone : nil
        let envelopes = AudioEnvelope.of([plan.systemAudio, plan.microphone] + (clean.map { [$0] } ?? []), using: ffmpeg)
        let raw = envelopes[1]
        return Result(
            systemAudio: envelopes[0].flatMap { s in raw.map { TrackAlignment.measure(reference: $0, other: s) } },
            cleanMicrophone: clean == nil ? nil : envelopes[2].flatMap { c in raw.map { TrackAlignment.measure(reference: $0, other: c) } },
            timing: RecordingInfo.read(plan.directory)?.timing)
    }
}
