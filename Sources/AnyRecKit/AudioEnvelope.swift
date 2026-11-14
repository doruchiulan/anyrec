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

    /// This track as a mix heard it with `key` ducking it: silent for as long as the
    /// key is above `threshold`, and for `release` after it drops below. The rest is
    /// untouched. Frames are in sample units, so a full-scale threshold is scaled
    /// before it gets here.
    public func held(under key: AudioEnvelope, threshold: Double, release: TimeInterval)
        -> AudioEnvelope
    {
        let hold = Self.index(at: release)
        var quietUntil = -1
        let heldFrames = frames.indices.map { index -> Double in
            if index < key.frames.count, key.frames[index] > threshold {
                quietUntil = index + hold
            }
            return index <= quietUntil ? 0 : frames[index]
        }
        return AudioEnvelope(frames: heldFrames)
    }

    /// This track with everything outside `spans` silenced.
    public func only(during spans: [Range<TimeInterval>]) -> AudioEnvelope {
        AudioEnvelope(
            frames: frames.indices.map { index in
                let time = Self.time(of: index)
                return spans.contains { $0.contains(time) } ? frames[index] : 0
            })
    }

    /// Decoding is the cost — tens of seconds for an hour-long track — and a pass reads
    /// the same two tracks for bleed, speech and attribution, then again for the next
    /// regeneration. So the last few envelopes are remembered, keyed by path, size and
    /// modification time: a track that changes is decoded again.
    public static func of(_ url: URL, using ffmpeg: String) -> AudioEnvelope? {
        let key = Memo.key(url)
        if let key, let cached = Memo.shared.value(for: key) { return cached }
        guard let samples = decode(url, using: ffmpeg) else { return nil }
        let envelope = AudioEnvelope(frames: rms(of: samples))
        if let key { Memo.shared.store(envelope, for: key) }
        return envelope
    }

    /// Several tracks decoded side by side, in the order given.
    public static func of(_ urls: [URL], using ffmpeg: String) -> [AudioEnvelope?] {
        var results = [AudioEnvelope?](repeating: nil, count: urls.count)
        results.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: urls.count) { index in
                slots[index] = of(urls[index], using: ffmpeg)
            }
        }
        return results
    }

    private final class Memo: @unchecked Sendable {
        static let shared = Memo()
        static let capacity = 6
        private let lock = NSLock()
        private var entries: [(key: String, envelope: AudioEnvelope)] = []

        static func key(_ url: URL) -> String? {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
            return "\(url.standardizedFileURL.path)|\(size)|\(modified.timeIntervalSince1970)"
        }

        func value(for key: String) -> AudioEnvelope? {
            lock.withLock { entries.first { $0.key == key }?.envelope }
        }

        func store(_ envelope: AudioEnvelope, for key: String) {
            lock.withLock {
                entries.removeAll { $0.key == key }
                entries.append((key, envelope))
                if entries.count > Self.capacity { entries.removeFirst() }
            }
        }
    }

    static func rms(of samples: [Int16]) -> [Double] {
        stride(from: 0, to: max(0, samples.count - frame + 1), by: frame).map { start in
            let window = samples[start..<(start + frame)]
            return (window.map { Double($0) * Double($0) }.reduce(0, +) / Double(frame)).squareRoot()
        }
    }

    private static func decode(_ url: URL, using ffmpeg: String) -> [Int16]? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("anyrec-envelope-\(UUID().uuidString).raw")
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
