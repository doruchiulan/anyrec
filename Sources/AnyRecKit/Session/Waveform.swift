import AVFoundation
import Accelerate
import Foundation

/// A recording's loudness over time, cut into `buckets` columns for drawing. Read with
/// AVFoundation off the audio tracks, so it needs no ffmpeg and works wherever playback does.
///
/// Decoding is the cost, not the arithmetic: a 100-minute call is two AAC tracks and four
/// seconds of CPU however the samples are summed. So it is worked out once per recording
/// and kept beside the tracks as `waveform.json` — a derived file, like `call.mp4`, that
/// can be deleted and is simply made again.
public enum Waveform {
    public static let fileName = "waveform.json"
    public static let columns = 120

    /// The recording's envelope, read from its file when it has one and decoded (then
    /// written) when it has not. Slow the first time; call it off the main thread.
    public static func of(_ directory: URL, duration: TimeInterval) -> [Float] {
        let cache = directory.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: cache),
            let peaks = try? JSONDecoder().decode([Float].self, from: data),
            peaks.count == columns
        {
            return peaks
        }
        let plan = OutputPlan(directory: directory)
        let peaks = peaks(of: [plan.systemAudio, plan.microphone], buckets: columns, duration: duration)
        if !peaks.isEmpty, let data = try? JSONEncoder().encode(peaks) {
            try? data.write(to: cache, options: .atomic)
        }
        return peaks
    }

    /// 0...1 per bucket, the loudest of the files given. Empty when none could be read.
    public static func peaks(of files: [URL], buckets: Int, duration: TimeInterval) -> [Float] {
        guard buckets > 0, duration > 0 else { return [] }
        let present = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        var results = [[Float]?](repeating: nil, count: present.count)
        results.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: present.count) { index in
                slots[index] = envelope(of: present[index], buckets: buckets, duration: duration)
            }
        }
        let read = results.compactMap { $0 }
        guard !read.isEmpty else { return [] }
        let merged = (0..<buckets).map { index in read.map { $0[index] }.max() ?? 0 }
        guard let loudest = merged.max(), loudest > 0 else { return [] }
        return merged.map { $0 / loudest }
    }

    /// `AVAssetReaderTrackOutput` throws on anything under 8 kHz, which is still far more
    /// than a 120-column envelope can show.
    static let rate = 8_000.0

    private static func envelope(of file: URL, buckets: Int, duration: TimeInterval) -> [Float]? {
        let asset = AVURLAsset(url: file)
        guard let track = asset.tracks(withMediaType: .audio).first,
            let reader = try? AVAssetReader(asset: asset)
        else { return nil }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
            ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return nil }

        /// Samples per column, rounded up so the last column is never left empty.
        let span = max(1, Int((duration * rate / Double(buckets)).rounded(.up)))
        var sums = [Float](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
        var position = 0
        var samples: [Float] = []

        while let buffer = output.copyNextSampleBuffer(),
            let block = CMSampleBufferGetDataBuffer(buffer)
        {
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            if samples.count < count { samples = [Float](repeating: 0, count: count) }
            samples.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                    destination: $0.baseAddress!)
            }
            var offset = 0
            samples.withUnsafeBufferPointer { pointer in
                while offset < count {
                    let bucket = min(buckets - 1, position / span)
                    /// The rest of this column, or the rest of the buffer.
                    let run = bucket == buckets - 1
                        ? count - offset : min(count - offset, span - position % span)
                    var squares: Float = 0
                    vDSP_svesq(pointer.baseAddress! + offset, 1, &squares, vDSP_Length(run))
                    sums[bucket] += squares
                    counts[bucket] += run
                    offset += run
                    position += run
                }
            }
        }
        return zip(sums, counts).map { $0.1 == 0 ? 0 : ($0.0 / Float($0.1)).squareRoot() }
    }
}
