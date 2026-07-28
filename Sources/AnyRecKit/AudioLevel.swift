import AVFoundation
import Foundation

public enum AudioTrack: String, Sendable, CaseIterable {
    case systemAudio = "call audio"
    case microphone = "microphone"
}

/// A level reading in dBFS, where 0 is full scale and `floor` is digital silence.
public struct AudioLevel: Sendable, Equatable {
    public static let floor: Float = -120

    public let peak: Float
    public let rms: Float

    public init(peak: Float, rms: Float) {
        self.peak = peak
        self.rms = rms
    }

    public static let silence = AudioLevel(peak: floor, rms: floor)

    public var isSilent: Bool { peak <= -80 }

    /// Audible, but far below speech — usually means the wrong input device.
    public var isRoomTone: Bool { !isSilent && peak < -35 }
}

/// Peak and RMS straight off the sample buffers, before they reach the encoder.
public enum AudioLevelMeter {
    public static func measure(_ sampleBuffer: CMSampleBuffer) -> AudioLevel? {
        guard
            let format = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return nil }

        var size = 0
        guard
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: &size,
                bufferListOut: nil,
                bufferListSize: 0,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: nil
            ) == noErr, size > 0
        else { return nil }

        let storage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?

        guard
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: list,
                bufferListSize: size,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer
            ) == noErr
        else { return nil }

        return withExtendedLifetime(blockBuffer) {
            level(of: UnsafeMutableAudioBufferListPointer(list), asbd: asbd)
        }
    }

    private static func level(
        of buffers: UnsafeMutableAudioBufferListPointer,
        asbd: AudioStreamBasicDescription
    ) -> AudioLevel? {
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var peak: Float = 0
        var sumSquares: Double = 0
        var count = 0

        for buffer in buffers {
            let scanned: Scan? =
                switch (isFloat, asbd.mBitsPerChannel) {
                case (true, 32): scan(buffer, as: Float.self) { abs($0) }
                case (false, 16): scan(buffer, as: Int16.self) { abs(Float($0) / 32_768) }
                case (false, 32): scan(buffer, as: Int32.self) { abs(Float($0) / 2_147_483_648) }
                default: nil
                }
            guard let scanned else { return nil }
            peak = max(peak, scanned.peak)
            sumSquares += scanned.sumSquares
            count += scanned.count
        }

        guard count > 0 else { return nil }
        let rms = Float((sumSquares / Double(count)).squareRoot())
        return AudioLevel(peak: dBFS(peak), rms: dBFS(rms))
    }

    private struct Scan {
        var peak: Float
        var sumSquares: Double
        var count: Int
    }

    private static func scan<Sample>(
        _ buffer: AudioBuffer, as type: Sample.Type, magnitude: (Sample) -> Float
    ) -> Scan {
        guard let data = buffer.mData else { return Scan(peak: 0, sumSquares: 0, count: 0) }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Sample>.size
        let samples = data.assumingMemoryBound(to: Sample.self)

        var peak: Float = 0
        var sumSquares: Double = 0
        for index in 0..<count {
            let value = magnitude(samples[index])
            peak = max(peak, value)
            sumSquares += Double(value) * Double(value)
        }
        return Scan(peak: peak, sumSquares: sumSquares, count: count)
    }

    public static func dBFS(_ amplitude: Float) -> Float {
        amplitude <= 0 ? AudioLevel.floor : max(AudioLevel.floor, 20 * log10(amplitude))
    }
}
