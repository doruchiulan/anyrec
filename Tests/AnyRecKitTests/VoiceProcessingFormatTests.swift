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
        #expect(fold.outputVolume == 0)
    }
}
