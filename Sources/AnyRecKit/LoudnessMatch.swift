import Foundation

/// What ffmpeg's EBU R128 meter reports about one track: integrated loudness and true peak.
public struct Loudness: Sendable, Equatable, Codable {
    public let integrated: Double
    public let truePeak: Double

    public init(integrated: Double, truePeak: Double) {
        self.integrated = integrated
        self.truePeak = truePeak
    }

    /// The meter bottoms out at -70 LUFS, and nothing that quiet holds speech.
    public var isSilent: Bool { integrated < -60 }
}

/// dB applied to each track on its way into the mix. The recorded files are never rewritten.
public struct TrackGains: Sendable, Equatable, Codable {
    public var systemAudio: Double
    public var microphone: Double

    public static let none = TrackGains(systemAudio: 0, microphone: 0)

    public init(systemAudio: Double, microphone: Double) {
        self.systemAudio = systemAudio
        self.microphone = microphone
    }
}

/// Balances the two sides of a call by loudness rather than by peak.
///
/// Speech peaks as high as continuous call audio but averages far below it, so
/// summing the tracks raw buries whoever is talking in a quiet room.
public enum LoudnessMatch {
    /// Under this the difference is not worth a filter.
    static let threshold = 3.0
    /// The most the quieter track is raised. Past it, what is raised is mostly its noise.
    static let maximumBoost = 24.0
    /// Where the raised track is limited (dBFS), so raising it cannot clip.
    static let ceiling = -2.0

    /// Raises the quieter track to the louder one's loudness (up to `maximumBoost`), and
    /// never lowers the louder one: the mix limits the raised track at `ceiling` instead.
    /// Taking the difference off the louder track made the whole file quiet: on a
    /// headphone Teams call the microphone measured 29 dB under the call with a peak near
    /// full scale, and the call went into the merge 29 dB down, at −46 LUFS.
    public static func gains(systemAudio: Loudness?, microphone: Loudness?) -> TrackGains {
        guard let systemAudio, let microphone, !systemAudio.isSilent, !microphone.isSilent
        else { return .none }

        let difference = systemAudio.integrated - microphone.integrated
        guard abs(difference) >= threshold else { return .none }

        let boost = min(abs(difference), maximumBoost)
        return difference > 0
            ? TrackGains(systemAudio: 0, microphone: boost)
            : TrackGains(systemAudio: boost, microphone: 0)
    }

    /// `ebur128` reports the same integrated loudness and true peak as `loudnorm`'s
    /// analysis pass in a fraction of the time — measured on a 76-minute call, 12 s and
    /// 17 s against 63 s and 123 s — because it does not resample to 192 kHz to do it.
    /// `filter` goes before the meter: the microphone is measured through the mix's mute
    /// gate, as the mix hears it.
    public static func measure(_ url: URL, using ffmpeg: String, through filter: String? = nil) -> Loudness? {
        let meter = "ebur128=peak=true:framelog=quiet"
        let arguments = [
            "-nostdin", "-hide_banner", "-nostats", "-i", url.path,
            "-af", filter.map { "\($0),\(meter)" } ?? meter, "-f", "null", "-",
        ]
        guard let result = try? Shell.run(ffmpeg, arguments) else { return nil }
        return parse(result.combined)
    }

    /// The summary ebur128 prints when the stream ends: `I:` under "Integrated loudness"
    /// and `Peak:` under "True peak". Silence reads as -70 LUFS and a peak of -inf.
    static func parse(_ log: String) -> Loudness? {
        guard let summary = log.range(of: "Summary:", options: .backwards) else { return nil }
        let tail = log[summary.upperBound...]
        guard let integrated = value(after: "I:", in: tail, following: "Integrated loudness:"),
              let peak = value(after: "Peak:", in: tail, following: "True peak:") else { return nil }
        return Loudness(integrated: integrated, truePeak: peak)
    }

    private static func value(after key: String, in text: Substring, following section: String) -> Double? {
        guard let heading = text.range(of: section) else { return nil }
        let rest = text[heading.upperBound...]
        guard let label = rest.range(of: key) else { return nil }
        let number = rest[label.upperBound...].drop { $0 == " " || $0 == "\t" }
            .prefix { !$0.isWhitespace }
        if number == "-inf" { return -.infinity }
        return Double(number)
    }
}
