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
}
