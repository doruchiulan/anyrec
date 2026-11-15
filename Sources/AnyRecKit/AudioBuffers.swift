import AVFoundation
import CoreMedia
import Foundation

/// Moving uncompressed audio between `CMSampleBuffer`, which capture and the writers deal
/// in, and `AVAudioPCMBuffer`, which conversion and silence are made in.
enum AudioBuffers {
    /// The buffer's format, when it is linear PCM that `AVAudioFormat` can describe.
    static func format(of sample: CMSampleBuffer) -> AVAudioFormat? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM else { return nil }
        return AVAudioFormat(cmAudioFormatDescription: description)
    }

    /// Seconds of audio in the buffer, from its frame count and rate: what it fills in a
    /// file, whatever its duration field says.
    static func length(of sample: CMSampleBuffer) -> Double {
        let frames = Double(CMSampleBufferGetNumSamples(sample))
        let rate = CMSampleBufferGetFormatDescription(sample)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 0
        if rate > 0 { return frames / rate }
        let duration = CMSampleBufferGetDuration(sample).seconds
        return duration.isFinite ? max(0, duration) : 0
    }

    /// A copy of the buffer's samples, in its own format.
    static func pcm(_ sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return nil }
        return buffer
    }

    /// `frames` of digital silence in `format`.
    static func silence(_ format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
        }
        return buffer
    }

    /// A copy of `buffer` as a sample buffer presented at `time`. The data is copied, so
    /// the source may be reused as soon as this returns.
    static func sample(_ buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: buffer.format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
            let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: format, sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList) == noErr else { return nil }
        return sample
    }
}

/// Audio arriving in another format than a track was started in, brought back to it.
///
/// A track's encoder is built from its first buffer, and AVAssetWriter does not follow a
/// change after that: measured, buffers at 24 kHz appended to a track started at 48 kHz
/// were encoded as though they were 48 kHz, half as long and an octave up, and a change
/// from mono to stereo failed the writer and left a file with no `moov` that nothing could
/// open. A microphone switched mid-call changes both — AirPods as an input run at 16 or
/// 24 kHz, the built-in microphone at 48 — so every buffer is converted to the track's
/// first format before it reaches the writer.
final class AudioConformer {
    let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(format: AVAudioFormat) {
        self.format = format
    }

    /// The buffer in the track's format, presented at its own time. Nil when it cannot be
    /// read or converted; the buffer itself when it is already in the track's format.
    func conform(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let source = AudioBuffers.format(of: sample) else { return nil }
        if AudioBuffers.same(source.streamDescription.pointee, format.streamDescription.pointee) { return sample }
        if converter.map({ !AudioBuffers.same($0.inputFormat.streamDescription.pointee, source.streamDescription.pointee) }) ?? true {
            converter = AVAudioConverter(from: source, to: format)
        }
        guard let converter, let input = AudioBuffers.pcm(sample, format: source) else { return nil }
        let ratio = format.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var handed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if handed {
                state.pointee = .noDataNow
                return nil
            }
            handed = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return AudioBuffers.sample(output, at: CMSampleBufferGetPresentationTimeStamp(sample))
    }
}

extension AudioBuffers {
    static func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket
            && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
    }
}
