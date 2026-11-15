import Foundation

/// How far one recorded track runs behind another, measured from sound both of them heard.
///
/// ScreenCaptureKit stamps its system-audio and microphone buffers on its own, and the two
/// do not agree: on a speakerphone Slack call the far end's echo in `microphone.m4a` sat
/// 510 ms *ahead* of the same words in `system-audio.m4a` for the whole call, and 60 ms on
/// a Teams call. An echo cannot precede what caused it, so that is a timestamp offset, not
/// a room. Left in, the duck keyed on the system track opens half a second after every
/// far-end phrase has started leaking, and every far-end turn lands half a second late
/// against the owner's.
///
/// The measurement compares how loudness *changes* — the frame-to-frame difference of the
/// log envelopes, syllable onsets and ends — over windows spread across the call, and asks
/// in each which lag lines them up best. Changes rather than levels because of turn-taking:
/// while the owner talks the microphone is loud and the call quiet, which drags a level
/// correlation towards zero however strong the echo, while the owner's syllables merely
/// fail to match anything in the call. On the real recordings a window with echo correlates
/// at 0.53–0.80 at the true lag, and one without — headphones — at about 0.05, the worst
/// 0.27. So a lag is accepted only from windows that clear `minimumCorrelation` and only
/// when they agree; otherwise the answer is "not measurable", which is the answer for every
/// recording made on headphones.
public struct TrackOffset: Codable, Equatable, Sendable {
    /// Seconds the measured track trails the reference: positive when its sound arrives
    /// later in its file than the same sound in the reference. Nil when not measurable.
    public let seconds: Double?
    /// The median peak correlation of the windows that agreed; when nothing agreed, the
    /// best correlation any window reached, so "not measurable" says how close it came.
    public let confidence: Double
    /// Windows whose lag was used.
    public let windowsUsed: Int
    public let windowsTried: Int
    /// The lag's change over the call, seconds per hour, from a straight line through the
    /// windows used. Nil with fewer than three.
    public let driftPerHour: Double?

    public init(seconds: Double?, confidence: Double, windowsUsed: Int, windowsTried: Int, driftPerHour: Double? = nil) {
        self.seconds = seconds
        self.confidence = confidence
        self.windowsUsed = windowsUsed
        self.windowsTried = windowsTried
        self.driftPerHour = driftPerHour
    }

    public var isMeasured: Bool { seconds != nil }
}

public enum TrackAlignment {
    /// 50 s windows: long enough that turn-taking averages out, short enough that a
    /// ten-minute call still gets several.
    static let window: TimeInterval = 50
    /// The furthest lag looked for either way. The worst offset seen was half a second.
    static let maximumLag: TimeInterval = 2
    /// Echo correlates at 0.53–0.80 at its lag, no echo at about 0.05 and never above 0.27.
    static let minimumCorrelation = 0.35
    static let singleWindowCorrelation = 0.5
    /// Windows used have to land within this of their median.
    static let agreement: TimeInterval = 0.04
    static let maximumWindows = 8
    /// Below this the shortest call has no window worth reading.
    static let shortestWindow: TimeInterval = 20

    /// The lag of `other` behind `reference`. Both are envelopes of the same recording.
    public static func measure(reference: AudioEnvelope, other: AudioEnvelope) -> TrackOffset {
        let a = changes(reference.frames), b = changes(other.frames)
        let count = min(a.count, b.count)
        let lag = AudioEnvelope.index(at: maximumLag)
        let length = min(AudioEnvelope.index(at: window), count - 2 * lag)
        guard length >= AudioEnvelope.index(at: shortestWindow) else {
            return TrackOffset(seconds: nil, confidence: 0, windowsUsed: 0, windowsTried: 0)
        }
        let span = count - 2 * lag - length
        let windows = max(1, min(maximumWindows, span / max(1, length / 2) + 1))
        let starts = (0..<windows).map { lag + (windows == 1 ? 0 : span * $0 / (windows - 1)) }

        let peaks = starts.map { start in peak(a, b, start: start, length: length, lag: lag) }
        let strong = peaks.enumerated().filter { $0.element.correlation >= minimumCorrelation }
        let best = peaks.map(\.correlation).max() ?? 0
        guard !strong.isEmpty else {
            return TrackOffset(seconds: nil, confidence: best, windowsUsed: 0, windowsTried: windows)
        }
        let centre = median(strong.map(\.element.lag))
        let tolerance = agreement / AudioEnvelope.frameDuration
        let agreeing = strong.filter { abs($0.element.lag - centre) <= tolerance }
        /// Two windows and a third of all of them, and most of the strong ones: a far end
        /// that is quiet for half the call leaves half the windows weak, which says
        /// nothing against the rest, but one strong window on its own is a coincidence.
        /// A call too short for two windows needs its one to be clearly echo.
        let enough = windows == 1
            ? agreeing.count == 1 && agreeing[0].element.correlation >= singleWindowCorrelation
            : agreeing.count >= 2 && agreeing.count * 3 >= windows && agreeing.count * 2 > strong.count
        guard enough else {
            return TrackOffset(seconds: nil, confidence: best, windowsUsed: 0, windowsTried: windows)
        }
        let lags = agreeing.map(\.element.lag)
        let times = agreeing.map { AudioEnvelope.time(of: starts[$0.offset] + length / 2) }
        return TrackOffset(
            seconds: median(lags) * AudioEnvelope.frameDuration,
            confidence: median(agreeing.map(\.element.correlation)),
            windowsUsed: agreeing.count, windowsTried: windows,
            driftPerHour: slope(times, lags.map { $0 * AudioEnvelope.frameDuration }).map { $0 * 3_600 })
    }

    /// Loudness is compared in decibels, so a quiet echo counts as much as the loud
    /// original it copies, and as its change from one frame to the next. One sample unit
    /// keeps digital silence finite.
    static func changes(_ frames: [Double]) -> [Double] {
        let levels = frames.map { log($0 + 1) }
        return levels.indices.map { $0 == 0 ? 0 : levels[$0] - levels[$0 - 1] }
    }

    /// The best lag in frames for one window of `a`, refined between frames by a parabola
    /// through the peak and its neighbours, and the normalised correlation there.
    static func peak(_ a: [Double], _ b: [Double], start: Int, length: Int, lag: Int)
        -> (lag: Double, correlation: Double)
    {
        let reference = centred(a[start..<(start + length)])
        let norm = (reference.reduce(0) { $0 + $1 * $1 }).squareRoot()
        var scores: [Double] = []
        scores.reserveCapacity(2 * lag + 1)
        for shift in -lag...lag {
            let other = centred(b[(start + shift)..<(start + shift + length)])
            let otherNorm = (other.reduce(0) { $0 + $1 * $1 }).squareRoot()
            var dot = 0.0
            for index in 0..<length { dot += reference[index] * other[index] }
            scores.append(norm > 0 && otherNorm > 0 ? dot / (norm * otherNorm) : 0)
        }
        let index = scores.indices.max { scores[$0] < scores[$1] } ?? lag
        var fraction = 0.0
        if index > 0, index < scores.count - 1 {
            let curve = scores[index - 1] - 2 * scores[index] + scores[index + 1]
            if curve < 0 { fraction = 0.5 * (scores[index - 1] - scores[index + 1]) / curve }
        }
        return (Double(index - lag) + fraction, scores[index])
    }

    private static func centred(_ slice: ArraySlice<Double>) -> [Double] {
        let mean = slice.reduce(0, +) / Double(max(1, slice.count))
        return slice.map { $0 - mean }
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    private static func slope(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count >= 3 else { return nil }
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
        let sxx = x.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 0 else { return nil }
        return zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
    }
}

extension AudioEnvelope {
    /// This track moved earlier by `seconds` (later when negative): what was at
    /// `t + seconds` is now at `t`. The end is padded with silence, or the start when it
    /// moves later, and fractions of a frame are interpolated.
    public func advanced(by seconds: TimeInterval) -> AudioEnvelope {
        guard seconds != 0, !frames.isEmpty else { return self }
        let shift = seconds / Self.frameDuration
        let count = frames.count
        return AudioEnvelope(frames: (0..<count).map { index in
            let position = Double(index) + shift
            let low = Int(position.rounded(.down))
            let fraction = position - Double(low)
            let at = { (i: Int) in i >= 0 && i < count ? frames[i] : 0 }
            return fraction < 1e-9 ? at(low) : at(low) * (1 - fraction) + at(low + 1) * fraction
        })
    }
}
