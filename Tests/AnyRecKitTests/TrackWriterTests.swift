import AVFoundation
import Foundation
import Testing

@testable import AnyRecKit

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
            .appendingPathComponent("anyrec-writer-\(UUID().uuidString)")
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
            .appendingPathComponent("anyrec-writer-\(UUID().uuidString)")
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

/// A microphone switched mid-call stops for a moment and comes back on another device, in
/// another format. The track has to keep its time and keep encoding.
@Suite("TrackWriter across a device change")
struct TrackWriterDeviceChangeTests {
    @Test("writes a gap in the stamps as silence, so what follows keeps its time")
    func gapIsSilence() async throws {
        let (url, cleanup) = try Self.scratch()
        defer { cleanup() }
        let start = CMTime(seconds: 100, preferredTimescale: 48_000)
        let writer = try Self.writer(url, rate: 48_000, channels: 1)
        var t = 100.0
        t = Self.feed(writer, from: t, seconds: 3, rate: 48_000, channels: 1, frames: 1_024, start: start)
        t += 2
        _ = Self.feed(writer, from: t, seconds: 3, rate: 48_000, channels: 1, frames: 1_024, start: start)
        _ = await writer.finish()

        #expect(writer.gaps.count == 1)
        #expect(abs((writer.gaps.first?.at ?? 0) - 3) < 0.03 && abs((writer.gaps.first?.seconds ?? 0) - 2) < 0.03)
        let levels = try Self.levels(url)
        #expect(abs(Double(levels.count) / 10 - 8) < 0.1, "8 s long, not 6")
        #expect(levels[5..<25].allSatisfy { $0 > 0.1 })
        #expect(levels[33..<48].allSatisfy { $0 < 0.001 }, "the gap is silent")
        #expect(levels[52..<78].allSatisfy { $0 > 0.1 }, "what follows starts at 5 s")
    }

    @Test("converts a new device's rate and channels to the track's, rather than mis-encoding or failing")
    func formatChange() async throws {
        let (url, cleanup) = try Self.scratch()
        defer { cleanup() }
        let start = CMTime(seconds: 100, preferredTimescale: 48_000)
        let writer = try Self.writer(url, rate: 48_000, channels: 1)
        var t = 100.0
        t = Self.feed(writer, from: t, seconds: 3, rate: 48_000, channels: 1, frames: 1_024, start: start)
        t += 0.5
        /// AirPods as an input: 24 kHz, and here two channels to be sure both are handled.
        _ = Self.feed(writer, from: t, seconds: 3, rate: 24_000, channels: 2, frames: 480, start: start)
        #expect(await writer.finish() > 0)
        #expect(writer.samplesDropped == 0)

        let levels = try Self.levels(url)
        #expect(abs(Double(levels.count) / 10 - 6.5) < 0.1, "the 24 kHz part runs its own three seconds")
        #expect(levels[33..<34].allSatisfy { $0 < 0.001 })
        #expect(levels[37..<63].allSatisfy { $0 > 0.1 })
    }

    @Test("skips a buffer stamped wholly inside what is already written")
    func overlap() async throws {
        let (url, cleanup) = try Self.scratch()
        defer { cleanup() }
        let start = CMTime(seconds: 100, preferredTimescale: 48_000)
        let writer = try Self.writer(url, rate: 48_000, channels: 1)
        let t = Self.feed(writer, from: 100, seconds: 2, rate: 48_000, channels: 1, frames: 1_024, start: start)
        _ = Self.feed(writer, from: t - 1, seconds: 0.5, rate: 48_000, channels: 1, frames: 1_024, start: start)
        _ = Self.feed(writer, from: t, seconds: 1, rate: 48_000, channels: 1, frames: 1_024, start: start)
        _ = await writer.finish()
        #expect(writer.gaps.isEmpty)
        let count = try Self.levels(url).count
        #expect(abs(count - 30) <= 1 && writer.samplesWritten == 139, "\(count) tenths, \(writer.samplesWritten) written")
    }

    static func scratch() throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory.appendingPathComponent("microphone.m4a"), { try? FileManager.default.removeItem(at: directory) })
    }

    static func writer(_ url: URL, rate: Double, channels: UInt32) throws -> TrackWriter {
        let first = try #require(buffer(rate: rate, channels: channels, frames: 16, at: 0))
        return try TrackWriter(url: url, kind: .audio, formatHint: CMSampleBufferGetFormatDescription(first))
    }

    /// Returns where the next buffer would start.
    static func feed(_ writer: TrackWriter, from t: Double, seconds: Double, rate: Double, channels: UInt32,
                     frames: Int, start: CMTime) -> Double {
        var t = t
        for _ in 0..<Int(seconds * rate / Double(frames)) {
            if let sample = buffer(rate: rate, channels: channels, frames: frames, at: t) {
                writer.append(sample, sessionStart: start)
            }
            t += Double(frames) / rate
        }
        return t
    }

    static func buffer(rate: Double, channels: UInt32, frames: Int, at t: Double) -> CMSampleBuffer? {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            for index in 0..<frames {
                pcm.floatChannelData![channel][index] = Float(0.5 * sin(2 * .pi * 440 * (t + Double(index) / rate)))
            }
        }
        return AudioBuffers.sample(pcm, at: CMTime(seconds: t, preferredTimescale: 48_000 * 100))
    }

    /// RMS of each tenth of a second of the file, decoded to 48 kHz mono float.
    static func levels(_ url: URL) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack?
        Task {
            track = try? await asset.loadTracks(withMediaType: .audio).first
            semaphore.signal()
        }
        semaphore.wait()
        let output = AVAssetReaderTrackOutput(track: try #require(track), outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
        }
        let step = 4_800
        return stride(from: 0, to: samples.count - step + 1, by: step).map { offset in
            (samples[offset..<(offset + step)].reduce(0) { $0 + $1 * $1 } / Float(step)).squareRoot()
        }
    }
}
