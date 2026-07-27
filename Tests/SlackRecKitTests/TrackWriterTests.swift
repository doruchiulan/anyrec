import AVFoundation
import Foundation
import Testing

@testable import SlackRecKit

@Suite("TrackWriter")
struct TrackWriterTests {
    @Test("leaves a rate AAC can encode alone")
    func keepsUsableRates() {
        #expect(TrackWriter.encodableRate(48_000) == 48_000)
        #expect(TrackWriter.encodableRate(44_100) == 44_100)
        #expect(TrackWriter.encodableRate(96_000) == 96_000)
    }

    @Test("lifts a bluetooth headset's rate to one the encoder accepts")
    func liftsLowRates() {
        /// AirPods as an input, and the HFP rates below it.
        #expect(TrackWriter.encodableRate(16_000) == 48_000)
        #expect(TrackWriter.encodableRate(24_000) == 48_000)
        #expect(TrackWriter.encodableRate(8_000) == 48_000)
    }

    @Test("says which file failed and why, through localizedDescription")
    func readableError() {
        let error = WriterError.cannotStartWriting(
            URL(fileURLWithPath: "/tmp/microphone.m4a"), nil
        )

        #expect(error.localizedDescription == error.description)
        #expect(error.localizedDescription.contains("microphone.m4a"))
    }

    @Test("carries a writer failure out through the recorder's message")
    func recorderErrorReadable() {
        let error = RecorderError.streamStopped(
            WriterError.cannotAddInput(URL(fileURLWithPath: "/tmp/microphone.m4a"))
        )

        #expect(error.localizedDescription.contains("Capture stopped early"))
        #expect(error.localizedDescription.contains("microphone.m4a"))
    }

    @Test("writes a bluetooth-rate microphone track rather than failing the recording")
    func encodesLowRateAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slack-rec-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("microphone.m4a")

        let (buffer, format) = try #require(Self.tone(rate: 16_000, seconds: 0.5))
        let writer = try TrackWriter(url: url, kind: .audio, formatHint: format)
        writer.append(buffer, sessionStart: .zero)

        #expect(await writer.finish() == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("leaves no empty file behind when the writer cannot start")
    func removesFailedFile() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slack-rec-writer-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("microphone.m4a")

        /// The directory does not exist, so AVAssetWriter cannot be built at all.
        #expect(throws: (any Error).self) {
            try TrackWriter(url: url, kind: .audio, formatHint: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Mono float32, as ScreenCaptureKit delivers a microphone.
    private static func tone(
        rate: Double, seconds: Double
    ) -> (CMSampleBuffer, CMFormatDescription)? {
        let frames = Int(rate * seconds)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMFormatDescription?
        guard
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &format) == noErr, let format
        else { return nil }

        let samples = (0..<frames).map { Float(sin(2 * .pi * 440 * Double($0) / rate)) * 0.5 }
        let bytes = frames * 4
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr, let block
        else { return nil }
        _ = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                dataLength: bytes)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid
        )
        var buffer: CMSampleBuffer?
        guard
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer) == noErr,
            let buffer
        else { return nil }
        return (buffer, format)
    }
}
