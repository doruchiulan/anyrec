import Foundation
import ScreenCaptureKit
import Testing

@testable import AnyRecKit

@Suite("Recorder")
struct RecorderTests {
    private func stop(_ code: SCStreamError.Code) -> NSError {
        NSError(domain: SCStreamError.errorDomain, code: code.rawValue)
    }

    @Test("reads a vanished window as the end of the recording, not a failure")
    func windowClosed() {
        #expect(Recorder.endOfRecording(stop(.noCaptureSource)) != nil)
        #expect(Recorder.endOfRecording(stop(.userStopped)) != nil)
    }

    @Test("still fails on a stop it cannot account for")
    func realFailure() {
        #expect(Recorder.endOfRecording(stop(.internalError)) == nil)
        #expect(
            Recorder.endOfRecording(
                NSError(domain: NSPOSIXErrorDomain, code: SCStreamError.Code.noCaptureSource.rawValue)
            ) == nil)
    }

    @Test("a closed source requests finalization and preserves the normal saved outcome")
    func closesCapture() async throws {
        let (recorder, stream) = recording()
        #expect(!recorder.captureEnded)
        recorder.stream(stream, didStopWithError: stop(.noCaptureSource))
        #expect(recorder.captureEnded)
        let saved = try await recorder.stop()
        #expect(saved.endedEarly?.contains("closed") == true)
    }

    @Test("a system stop also requests finalization")
    func systemStop() async throws {
        let (recorder, stream) = recording()
        recorder.stream(stream, didStopWithError: stop(.userStopped))
        #expect(recorder.captureEnded)
        #expect(try await recorder.stop().endedEarly?.contains("Screen sharing") == true)
    }

    @Test("a capture failure requests finalization but remains an error")
    func failedCapture() async {
        let (recorder, stream) = recording()
        recorder.stream(stream, didStopWithError: stop(.internalError))
        #expect(recorder.captureEnded)
        do {
            _ = try await recorder.stop()
            Issue.record("The capture failure was swallowed")
        } catch {
            #expect(error is RecorderError)
        }
    }

    private func recording() -> (Recorder, SCStream) {
        let filter = SCContentFilter()
        let target = ResolvedTarget(filter: filter, width: 2, height: 2, describing: "Test window")
        let recorder = Recorder(options: CaptureOptions(), target: target,
                                plan: OutputPlan(directory: URL(fileURLWithPath: "/tmp/anyrec-stop-\(UUID())")))
        return (recorder, SCStream(filter: filter, configuration: SCStreamConfiguration(), delegate: nil))
    }
}
