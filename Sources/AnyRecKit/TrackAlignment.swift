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
    /// windows used (in the stretch with the most of them, when there are several). Nil
    /// with fewer than three.
    public let driftPerHour: Double?
    /// The lag stretch by stretch, between the device changes recorded in
    /// `recording.json`. Absent in older `mix.json` files, which held one lag for the call.
    public var sections: [Section]?

    /// One stretch of the call between device changes, measured on its own.
    public struct Section: Codable, Equatable, Sendable {
        /// Seconds on the reference track's timeline.
        public let start: TimeInterval
        public let end: TimeInterval
        /// The lag at `start`. Nil when this stretch was not measurable.
        public let seconds: Double?
        /// How the lag moves through the stretch, seconds an hour, when the windows show it
        /// moving by more than `TrackAlignment.followedDrift` over the stretch. Nil holds it.
        public let driftPerHour: Double?
        public let confidence: Double
        public let windowsUsed: Int
        public let windowsTried: Int

        public init(start: TimeInterval, end: TimeInterval, seconds: Double?, driftPerHour: Double? = nil,
                    confidence: Double, windowsUsed: Int, windowsTried: Int) {
            self.start = start
            self.end = end
            self.seconds = seconds
            self.driftPerHour = driftPerHour
            self.confidence = confidence
            self.windowsUsed = windowsUsed
            self.windowsTried = windowsTried
        }

        public var isMeasured: Bool { seconds != nil }
    }

    public init(seconds: Double?, confidence: Double, windowsUsed: Int, windowsTried: Int, driftPerHour: Double? = nil,
                sections: [Section]? = nil) {
        self.seconds = seconds
        self.confidence = confidence
        self.windowsUsed = windowsUsed
        self.windowsTried = windowsTried
        self.driftPerHour = driftPerHour
        self.sections = sections
    }

    public var isMeasured: Bool { seconds != nil }

    /// What the track is moved by, over the whole call. Each measured stretch keeps its own
    /// lag, drifting where it was seen to drift; a stretch that could not be measured takes
    /// the lag its nearest measured neighbour has at the edge they share. One measured
    /// stretch and no drift is one constant, the simple case. Nil when nothing was measured.
    public var shift: TrackShift? {
        guard let seconds else { return nil }
        let measured = (sections ?? []).filter(\.isMeasured)
        guard !measured.isEmpty, let sections else { return TrackShift(constant: seconds) }
        var pieces: [TrackShift.Piece] = []
        for section in sections {
            if let lag = section.seconds {
                pieces.append(.init(start: section.start, seconds: lag, driftPerHour: section.driftPerHour ?? 0))
                continue
            }
            let before = measured.last { $0.end <= section.start }
            let after = measured.first { $0.start >= section.end }
            let edge: Double
            if let before, let after {
                edge = section.start - before.end <= after.start - section.end
                    ? before.lag(at: before.end) : after.lag(at: after.start)
            } else if let before {
                edge = before.lag(at: before.end)
            } else {
                edge = after!.lag(at: after!.start)
            }
            pieces.append(.init(start: section.start, seconds: edge, driftPerHour: 0))
        }
        return TrackShift(pieces: pieces)
    }
}

extension TrackOffset.Section {
    func lag(at time: TimeInterval) -> Double {
        (seconds ?? 0) + (driftPerHour ?? 0) / 3_600 * (time - start)
    }
}

/// How far a track is moved at each moment of the call, so it sits on the reference
/// track's timeline: pieces that each hold a lag, or let it drift in a straight line, with
/// a step where the next one starts. A device change is a step; a clock running slightly
/// fast is a drift. Seconds earlier, as `AudioEnvelope.advanced(by:)` takes them.
public struct TrackShift: Codable, Equatable, Sendable {
    public struct Piece: Codable, Equatable, Sendable {
        /// Where the piece starts, seconds on the reference timeline.
        public let start: TimeInterval
        /// The lag at `start`.
        public let seconds: Double
        /// Its change through the piece, seconds an hour.
        public let driftPerHour: Double

        public init(start: TimeInterval, seconds: Double, driftPerHour: Double = 0) {
            self.start = start
            self.seconds = seconds
            self.driftPerHour = driftPerHour
        }

        var slope: Double { driftPerHour / 3_600 }
    }

    /// In order, the first from zero. Neighbours that say the same thing are one piece.
    public let pieces: [Piece]

    public init(pieces: [Piece]) {
        var merged: [Piece] = []
        for piece in pieces.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, last.driftPerHour == 0, piece.driftPerHour == 0,
               abs(last.seconds - piece.seconds) < Self.negligible { continue }
            merged.append(merged.isEmpty ? Piece(start: 0, seconds: piece.seconds - piece.slope * piece.start,
                                                 driftPerHour: piece.driftPerHour) : piece)
        }
        self.pieces = merged.isEmpty ? [Piece(start: 0, seconds: 0)] : merged
    }

    public init(constant seconds: Double) {
        pieces = [Piece(start: 0, seconds: seconds)]
    }

    public static let zero = TrackShift(constant: 0)

    /// Half a millisecond: less than a sample's worth of anything audible here.
    static let negligible = 0.0005

    /// The lag at `time` on the reference timeline.
    public func offset(at time: TimeInterval) -> Double {
        let piece = pieces.last { $0.start <= time } ?? pieces[0]
        return piece.seconds + piece.slope * (time - piece.start)
    }

    /// The one lag, when the shift is the same throughout.
    public var constant: Double? {
        pieces.count == 1 && pieces[0].driftPerHour == 0 ? pieces[0].seconds : nil
    }

    public var isZero: Bool { constant.map { abs($0) < Self.negligible } ?? false }

    /// Where a moment of the track's own file lands on the reference timeline: `u` minus
    /// the lag there. Exact within a drifting piece; a step changes it at once.
    public func referenceTime(of u: TimeInterval) -> TimeInterval {
        let piece = pieces.last { $0.start + $0.seconds <= u } ?? pieces[0]
        return (u - piece.seconds + piece.slope * piece.start) / (1 + piece.slope)
    }

    /// The shift as held lags, none more than `resolution` from the drifting line: what a
    /// player that can only cut and place whole stretches does with it. Each is
    /// `start..<end` on the reference timeline, read from `start + seconds` in the track.
    public func stretches(until duration: TimeInterval, resolution: TimeInterval = 0.005)
        -> [(start: TimeInterval, end: TimeInterval, seconds: Double)]
    {
        var result: [(start: TimeInterval, end: TimeInterval, seconds: Double)] = []
        for (index, piece) in pieces.enumerated() where piece.start < duration {
            let end = index + 1 < pieces.count ? min(pieces[index + 1].start, duration) : duration
            let step = piece.slope == 0 ? end - piece.start : max(1, resolution / abs(piece.slope))
            var at = piece.start
            while at < end {
                let next = min(end, at + step)
                result.append((at, next, piece.seconds + piece.slope * ((at + next) / 2 - piece.start)))
                at = next
            }
        }
        return result
    }
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

    /// The lag must move by more than this across a stretch for its drift to be followed.
    /// A window's lag is good to a few milliseconds; the drift measured on real calls,
    /// 12–34 ms an hour, only reaches this on calls longer than about twenty minutes.
    static let followedDrift: TimeInterval = 0.01
    /// More than this an hour is not a clock: something else moved the lag.
    static let largestDrift: TimeInterval = 0.5
    /// Windows that can fit a straight line.
    static let windowsForDrift = 4

    /// The lag of `other` behind `reference`. Both are envelopes of the same recording.
    ///
    /// Measured stretch by stretch, cut at `boundaries` (seconds on the reference timeline:
    /// the device changes recorded during capture), because a change of device can move
    /// the lag. Each stretch is measured with the rules above on windows of its own, and
    /// within a stretch the lag may drift in a straight line where enough windows show it
    /// moving. With no boundaries this is the one-stretch measurement it always was.
    public static func measure(reference: AudioEnvelope, other: AudioEnvelope, boundaries: [TimeInterval] = [])
        -> TrackOffset
    {
        let a = changes(reference.frames), b = changes(other.frames)
        let count = min(a.count, b.count)
        let cuts = boundaries.map { AudioEnvelope.index(at: $0) }.filter { $0 > 0 && $0 < count }
        let edges = ([0] + Set(cuts).sorted() + [count])
        let results = zip(edges, edges.dropFirst()).map { measure(a, b, from: $0, to: $1, of: count) }

        let used = results.flatMap(\.used)
        let tried = results.map(\.tried).reduce(0, +)
        let best = results.map(\.best).max() ?? 0
        guard !used.isEmpty else {
            return TrackOffset(seconds: nil, confidence: best, windowsUsed: 0, windowsTried: tried,
                               sections: results.map(\.section))
        }
        let busiest = results.max { $0.used.count < $1.used.count }!
        return TrackOffset(
            seconds: median(used.map(\.lag)),
            confidence: median(used.map(\.correlation)),
            windowsUsed: used.count, windowsTried: tried,
            driftPerHour: slope(busiest.used.map(\.time), busiest.used.map(\.lag)).map { $0 * 3_600 },
            sections: results.map(\.section))
    }

    private struct Window {
        let time: TimeInterval
        let lag: Double
        let correlation: Double
    }

    private struct Stretch {
        let section: TrackOffset.Section
        let used: [Window]
        let tried: Int
        let best: Double
    }

    /// One stretch, frames `start..<end` of `count`.
    private static func measure(_ a: [Double], _ b: [Double], from start: Int, to end: Int, of count: Int) -> Stretch {
        let lag = AudioEnvelope.index(at: maximumLag)
        let times = (AudioEnvelope.time(of: start), AudioEnvelope.time(of: end))
        /// Windows keep clear of the stretch's edges by the largest lag, so none reads
        /// across a device change, and of the ends of the tracks.
        let low = max(start, lag), high = min(end, count - lag)
        let length = min(AudioEnvelope.index(at: window), high - low)
        let nothing = { (tried: Int, best: Double) in
            Stretch(section: .init(start: times.0, end: times.1, seconds: nil, confidence: best, windowsUsed: 0,
                                   windowsTried: tried), used: [], tried: tried, best: best)
        }
        guard length >= AudioEnvelope.index(at: shortestWindow) else { return nothing(0, 0) }
        let span = high - low - length
        let windows = max(1, min(maximumWindows, span / max(1, length / 2) + 1))
        let starts = (0..<windows).map { low + (windows == 1 ? 0 : span * $0 / (windows - 1)) }

        let measured = starts.map { first in
            let found = peak(a, b, start: first, length: length, lag: lag)
            return Window(time: AudioEnvelope.time(of: first + length / 2),
                          lag: found.lag * AudioEnvelope.frameDuration, correlation: found.correlation)
        }
        let strong = measured.filter { $0.correlation >= minimumCorrelation }
        let best = measured.map(\.correlation).max() ?? 0
        guard !strong.isEmpty else { return nothing(windows, best) }
        let centre = median(strong.map(\.lag))
        var agreeing = strong.filter { abs($0.lag - centre) <= agreement }
        /// Two windows and a third of all of them, and most of the strong ones: a far end
        /// that is quiet for half the call leaves half the windows weak, which says
        /// nothing against the rest, but one strong window on its own is a coincidence.
        /// A call too short for two windows needs its one to be clearly echo.
        let enough = windows == 1
            ? agreeing.count == 1 && agreeing[0].correlation >= singleWindowCorrelation
            : agreeing.count >= 2 && agreeing.count * 3 >= windows && agreeing.count * 2 > strong.count
        guard enough else { return nothing(windows, best) }

        /// A drift is followed only when a line through the windows moves the lag by more
        /// than a window can be trusted to, and stays a clock's worth of drift. The line is
        /// then fitted again on every strong window near it, so windows at the ends of a long
        /// stretch that drifted away from the median are not left out.
        var line = fit(agreeing)
        if let fitted = line {
            let near = strong.filter { abs($0.lag - fitted.at(times: $0.time)) <= agreement }
            if near.count >= agreeing.count, let refitted = fit(near) {
                agreeing = near
                line = refitted
            }
        }
        let duration = times.1 - times.0
        if let fitted = line,
           agreeing.count >= windowsForDrift,
           abs(fitted.slope) * duration >= followedDrift,
           abs(fitted.slope) * 3_600 <= largestDrift {
            return Stretch(section: .init(start: times.0, end: times.1, seconds: fitted.at(times: times.0),
                                          driftPerHour: fitted.slope * 3_600,
                                          confidence: median(agreeing.map(\.correlation)),
                                          windowsUsed: agreeing.count, windowsTried: windows),
                           used: agreeing, tried: windows, best: best)
        }
        return Stretch(section: .init(start: times.0, end: times.1, seconds: median(agreeing.map(\.lag)),
                                      confidence: median(agreeing.map(\.correlation)),
                                      windowsUsed: agreeing.count, windowsTried: windows),
                       used: agreeing, tried: windows, best: best)
    }

    private struct Line {
        let slope: Double
        let intercept: Double
        func at(times time: Double) -> Double { intercept + slope * time }
    }

    private static func fit(_ windows: [Window]) -> Line? {
        let x = windows.map(\.time), y = windows.map(\.lag)
        guard let slope = slope(x, y) else { return nil }
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
        return Line(slope: slope, intercept: my - slope * mx)
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
        advanced(by: TrackShift(constant: seconds))
    }

    /// This track moved by a lag that changes over the call: what was at `t + lag(t)` is
    /// now at `t`, so a step in the lag skips or repeats a little of the track there and a
    /// drift stretches it, as the mixes' filter graphs do.
    public func advanced(by shift: TrackShift) -> AudioEnvelope {
        guard !shift.isZero, !frames.isEmpty else { return self }
        let count = frames.count
        return AudioEnvelope(frames: (0..<count).map { index in
            let position = Double(index) + shift.offset(at: Self.time(of: index)) / Self.frameDuration
            let low = Int(position.rounded(.down))
            let fraction = position - Double(low)
            let at = { (i: Int) in i >= 0 && i < count ? frames[i] : 0 }
            return fraction < 1e-9 ? at(low) : at(low) * (1 - fraction) + at(low + 1) * fraction
        })
    }
}
