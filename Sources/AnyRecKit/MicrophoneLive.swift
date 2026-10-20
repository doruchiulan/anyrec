import Foundation

/// When the call could hear the microphone.
///
/// Read from the call app while recording and left beside the tracks; anything the
/// microphone picked up outside these spans reached nobody — a word to someone in
/// the room, a cough, a keyboard — and has no business in the mix or under "Me".
public struct MicrophoneLive: Sendable, Equatable {
    public struct Transition: Sendable, Equatable {
        public let at: TimeInterval
        public let live: Bool

        public init(at: TimeInterval, live: Bool) {
            self.at = at
            self.live = live
        }
    }

    /// How long the recording ran, so the muted time can be said.
    public let duration: TimeInterval
    /// Seconds from the start of the recording.
    public let spans: [Range<TimeInterval>]

    public init(duration: TimeInterval, spans: [Range<TimeInterval>]) {
        self.duration = duration
        self.spans = spans
    }

    /// A recording opens with the call not listening — the first scan says otherwise
    /// at once if it is — and the last span closes when the recording does.
    public init(duration: TimeInterval, transitions: [Transition]) {
        var spans: [Range<TimeInterval>] = []
        var opened: TimeInterval?
        for transition in transitions {
            if transition.live {
                if opened == nil { opened = transition.at }
            } else if let start = opened {
                if transition.at > start { spans.append(start..<transition.at) }
                opened = nil
            }
        }
        if let start = opened, duration > start { spans.append(start..<duration) }
        self.init(duration: duration, spans: spans)
    }

    public var total: TimeInterval {
        spans.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// Worth saying only when the call was deaf to the microphone for a real stretch.
    public var note: String? {
        let muted = duration - total
        guard muted >= 1 else { return nil }
        return
            "The call was not listening to the microphone for \(Self.clock(muted)) of "
            + "\(Self.clock(duration)) — muted, or not yet in the call — so the microphone "
            + "is silent in call.mp4 and in the transcript for that time. Nothing on it "
            + "reached anyone."
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        let (hours, minutes, rest) = (whole / 3600, whole % 3600 / 60, whole % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    // MARK: - On disk

    /// `{"duration": 290.2, "live": [[12.0, 45.5], …]}`, next to the tracks.
    private struct File: Codable {
        var duration: TimeInterval
        var live: [[TimeInterval]]
    }

    public static func read(_ url: URL) -> MicrophoneLive? {
        guard let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else { return nil }
        let spans = file.live.compactMap { pair -> Range<TimeInterval>? in
            guard pair.count == 2, pair[0] < pair[1] else { return nil }
            return pair[0]..<pair[1]
        }
        return MicrophoneLive(duration: file.duration, spans: spans)
    }

    public func write(to url: URL) throws {
        let file = File(duration: duration, live: spans.map { [$0.lowerBound, $0.upperBound] })
        try JSONEncoder().encode(file).write(to: url, options: .atomic)
    }
}
