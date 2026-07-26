import Foundation

/// What ffmpeg's loudnorm analyser reports about one track.
public struct Loudness: Sendable, Equatable {
    public let integrated: Double
    public let truePeak: Double

    public init(integrated: Double, truePeak: Double) {
        self.integrated = integrated
        self.truePeak = truePeak
    }

    /// loudnorm bottoms out around -70 LUFS, and nothing that quiet holds speech.
    public var isSilent: Bool { integrated < -60 }
}

/// dB applied to each track on its way into the mix. The recorded files are never rewritten.
public struct TrackGains: Sendable, Equatable {
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
    /// Headroom kept above the boosted track, so raising it cannot clip.
    static let ceiling = -2.0

    /// Raises the quieter track as far as its headroom allows, then takes the rest
    /// off the louder one — so the two always match and neither can clip.
    public static func gains(systemAudio: Loudness?, microphone: Loudness?) -> TrackGains {
        guard let systemAudio, let microphone, !systemAudio.isSilent, !microphone.isSilent
        else { return .none }

        let difference = systemAudio.integrated - microphone.integrated
        guard abs(difference) >= threshold else { return .none }

        let quieter = difference > 0 ? microphone : systemAudio
        let boost = min(abs(difference), max(0, ceiling - quieter.truePeak))
        let cut = abs(difference) - boost

        return difference > 0
            ? TrackGains(systemAudio: -cut, microphone: boost)
            : TrackGains(systemAudio: boost, microphone: -cut)
    }

    public static func measure(_ url: URL, using ffmpeg: String) -> Loudness? {
        let arguments = [
            "-nostdin", "-i", url.path, "-af", "loudnorm=print_format=json", "-f", "null", "-",
        ]
        guard let result = try? Shell.run(ffmpeg, arguments) else { return nil }
        return parse(result.combined)
    }

    static func parse(_ log: String) -> Loudness? {
        guard let integrated = value("input_i", in: log), let peak = value("input_tp", in: log)
        else { return nil }
        return Loudness(integrated: integrated, truePeak: peak)
    }

    /// loudnorm quotes its numbers, so the value is whatever sits between the next two quotes.
    private static func value(_ key: String, in log: String) -> Double? {
        guard let key = log.range(of: "\"\(key)\"") else { return nil }
        let tail = log[key.upperBound...]
        guard let open = tail.firstIndex(of: "\"") else { return nil }
        let rest = tail[tail.index(after: open)...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return Double(rest[..<close])
    }
}
