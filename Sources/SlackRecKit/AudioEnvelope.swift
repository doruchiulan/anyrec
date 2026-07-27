import Foundation

/// Loudness over time: the shape of who-is-talking-when, which is what survives
/// a room when a waveform does not. Bleed detection compares two of these, speech
/// detection looks for where one rises, and attribution asks which of two is
/// louder while a line is being said.
public struct AudioEnvelope: Sendable, Equatable {
    /// 20 ms frames at 8 kHz. Fine enough that a sound and its echo land in the
    /// same frame, coarse enough that an hour of audio is a few thousand numbers.
    static let sampleRate = 8_000
    static let frame = 160
    static let frameDuration = Double(frame) / Double(sampleRate)

    public let frames: [Double]

    public init(frames: [Double]) { self.frames = frames }

    public var isEmpty: Bool { frames.isEmpty }
    public var peak: Double { frames.max() ?? 0 }
    public var duration: TimeInterval { Self.time(of: frames.count) }

    /// The quiet a track never goes below — room tone, preamp hiss, a fan. Read as
    /// a low percentile so a pause of any length cannot drag it up.
    public var noiseFloor: Double {
        guard !frames.isEmpty else { return 0 }
        return frames.sorted()[frames.count / 5]
    }

    static func time(of index: Int) -> TimeInterval { Double(index) * frameDuration }
    static func index(at time: TimeInterval) -> Int { Int(time / frameDuration) }

    /// Mean loudness over a span. Zero when the span falls outside the recording.
    public func level(from start: TimeInterval, to end: TimeInterval) -> Double {
        let first = max(0, Self.index(at: start))
        let last = min(frames.count, Self.index(at: end) + 1)
        guard first < last else { return 0 }
        return frames[first..<last].reduce(0, +) / Double(last - first)
    }

    public static func of(_ url: URL, using ffmpeg: String) -> AudioEnvelope? {
        guard let samples = decode(url, using: ffmpeg) else { return nil }
        return AudioEnvelope(frames: rms(of: samples))
    }

    static func rms(of samples: [Int16]) -> [Double] {
        stride(from: 0, to: max(0, samples.count - frame + 1), by: frame).map { start in
            let window = samples[start..<(start + frame)]
            return (window.map { Double($0) * Double($0) }.reduce(0, +) / Double(frame)).squareRoot()
        }
    }

    private static func decode(_ url: URL, using ffmpeg: String) -> [Int16]? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("slack-rec-envelope-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let arguments = [
            "-nostdin", "-v", "error", "-i", url.path,
            "-ac", "1", "-ar", "\(sampleRate)", "-f", "s16le", scratch.path,
        ]
        guard let result = try? Shell.run(ffmpeg, arguments), result.succeeded,
            let data = try? Data(contentsOf: scratch)
        else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
}
