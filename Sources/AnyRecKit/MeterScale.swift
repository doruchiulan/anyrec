import Foundation

/// Maps dBFS onto a bar, and onto a verdict about whether a track is usable.
public enum MeterScale {
    /// Quieter than this and the bar is empty; a call track below it is inaudible anyway.
    public static let minimum: Float = -60

    public static func fraction(_ dBFS: Float) -> Float {
        guard dBFS > minimum else { return 0 }
        return min(1, (dBFS - minimum) / -minimum)
    }

    public static func filled(_ dBFS: Float, width: Int) -> Int {
        guard width > 0 else { return 0 }
        return min(width, Int((Float(width) * fraction(dBFS)).rounded()))
    }

    public enum Zone: Sendable, Equatable {
        case silent
        case faint
        case healthy
        case hot
    }

    public static func zone(_ dBFS: Float) -> Zone {
        switch dBFS {
        case ..<(-80): .silent
        case ..<(-35): .faint
        case ..<(-1): .healthy
        default: .hot
        }
    }

    /// What to tell someone staring at a finished recording.
    public static func verdict(peak: Float, for track: AudioTrack) -> String? {
        switch zone(peak) {
        case .silent:
            "silent — nothing reached this track"
        case .faint:
            track == .microphone
                ? "very quiet — check the input device with `anyrec sources`"
                : "very quiet — was anything playing?"
        case .healthy:
            nil
        case .hot:
            "clipping — the source is too loud"
        }
    }

    public static func reading(_ dBFS: Float) -> String {
        dBFS <= AudioLevel.floor ? "  --  " : String(format: "%5.1f", dBFS)
    }
}
