import AVFoundation
import Foundation

/// A file's audio as whisper wants it: 16 kHz, mono, float. Read with AVFoundation, so
/// it needs no ffmpeg, and a second at a time, so a two-hour call at 48 kHz stereo is
/// never in memory at once — only its 16 kHz mono copy is.
enum AudioSamples {
    static let rate = 16_000.0

    enum Failure: Error, LocalizedError, CustomStringConvertible {
        case unreadable(URL)
        case conversion(String)

        var description: String {
            switch self {
            case .unreadable(let url): "\(url.lastPathComponent) has no audio that can be read."
            case .conversion(let reason): "The audio could not be converted: \(reason)"
            }
        }

        var errorDescription: String? { description }
    }

    static func read(_ url: URL, seconds: Double? = nil, start: Double = 0) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard source.sampleRate > 0,
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: source, to: target)
        else { throw Failure.unreadable(url) }

        guard start.isFinite, start >= 0, seconds.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw Failure.unreadable(url)
        }
        file.framePosition = AVAudioFramePosition(min(Double(file.length), start * source.sampleRate))
        let wanted = seconds.map {
            AVAudioFramePosition(min(Double(file.length), Double(file.framePosition) + $0 * source.sampleRate))
        } ?? file.length
        return try convert(file, through: wanted, using: converter)
    }

    private static func convert(
        _ file: AVAudioFile, through wanted: AVAudioFramePosition, using converter: AVAudioConverter
    ) throws -> [Float] {
        let source = file.processingFormat
        let chunk = AVAudioFrameCount(source.sampleRate)
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk),
            let output = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(rate) + 4_096)
        else { throw Failure.unreadable(file.url) }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(wanted - file.framePosition) / source.sampleRate * rate) + 4_096)
        var done = false
        while !done {
            let left = wanted - file.framePosition
            if left > 0 {
                try file.read(into: input, frameCount: min(chunk, AVAudioFrameCount(left)))
            }
            done = left <= 0 || input.frameLength == 0
            var handed = false
            var error: NSError?
            output.frameLength = 0
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if done {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if handed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                handed = true
                outStatus.pointee = .haveData
                return input
            }
            if status == .error { throw Failure.conversion(error?.localizedDescription ?? "unknown") }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
        }
        return samples
    }
}
