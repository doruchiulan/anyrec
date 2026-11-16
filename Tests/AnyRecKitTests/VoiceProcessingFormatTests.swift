import AVFoundation
import Foundation
import Testing

@testable import AnyRecKit

// Opt in because starting voice processing opens the local audio devices.
@Suite("Voice-processing I/O formats", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ANYREC_LIVE_AUDIO_TEST"] == "1"))
struct VoiceProcessingFormatTests {
    @Test("starts when the output connection initially has a different sample rate",
          arguments: [44_100.0, 96_000.0])
    func mismatchedOutput(outputRate: Double) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        defer {
            engine.stop()
            try? input.setVoiceProcessingEnabled(false)
        }
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2))
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: output)
        let microphoneRate = input.outputFormat(forBus: 0).sampleRate
        try #require(microphoneRate != outputRate)

        let fold = AVAudioMixerNode()
        let capture = try CleanMicrophone.connect(engine, through: fold)
        fold.installTap(onBus: 0, bufferSize: 1_024, format: capture) { _, _ in }
        defer { fold.removeTap(onBus: 0) }
        try engine.start()

        #expect(engine.isRunning)
        #expect(engine.outputNode.inputFormat(forBus: 0).sampleRate == microphoneRate)
        #expect(capture.sampleRate == microphoneRate)
        #expect(capture.channelCount == 1)
        #expect(fold.outputVolume == 1, "the track is tapped here, after this volume")
        #expect(engine.mainMixerNode.outputVolume == 0, "nothing reaches the speakers")
    }

    @Test("the tapped track carries the microphone, not silence")
    func carriesSignal() async throws {
        /// Without the grant macOS hands every process zeros, raw input included.
        try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                     "run from a terminal that has the Microphone grant")
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        defer {
            engine.stop()
            try? input.setVoiceProcessingEnabled(false)
        }
        let fold = AVAudioMixerNode()
        let capture = try CleanMicrophone.connect(engine, through: fold)
        let peak = Peak()
        fold.installTap(onBus: 0, bufferSize: 1_024, format: capture) { buffer, _ in
            guard let samples = buffer.floatChannelData?[0] else { return }
            peak.note((0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) })
        }
        defer { fold.removeTap(onBus: 0) }
        try engine.start()
        try await Task.sleep(for: .seconds(2))
        /// A room is never digitally silent; a tap after a zero volume always is.
        #expect(peak.value > 0, "every sample was zero: the tap is after a muted node")
    }
}

private final class Peak: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    var value: Float { lock.withLock { peak } }
    func note(_ sample: Float) { lock.withLock { peak = max(peak, sample) } }
}
