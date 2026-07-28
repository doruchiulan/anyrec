import Foundation
import AnyRecKit

/// Draws one audio track as a bar plus its numeric reading.
enum Meter {
    static func render(
        _ label: String, level: AudioLevel, sessionPeak: Float, width: Int
    ) -> String {
        let name = label.padding(toLength: 12, withPad: " ", startingAt: 0)
        let bar = bar(rms: level.rms, peak: level.peak, width: width)
        let now = MeterScale.reading(level.peak)
        let held = MeterScale.reading(sessionPeak)
        return "\(name)\(bar)  \(now)  \(styled("max \(held)", .dim))"
    }

    /// The bar fills to RMS; the current peak rides on top as a single marker.
    static func bar(rms: Float, peak: Float, width: Int) -> String {
        let filled = MeterScale.filled(rms, width: width)
        let marker = MeterScale.filled(peak, width: width)
        let colour = colour(for: peak)

        let cells = (0..<width).map { index -> String in
            if index == marker - 1, marker > filled { return styled("|", colour) }
            return index < filled ? styled("█", colour) : styled("·", .dim)
        }
        return cells.joined()
    }

    static func colour(for peak: Float) -> Style {
        switch MeterScale.zone(peak) {
        case .silent: .dim
        case .faint: .yellow
        case .healthy: .green
        case .hot: .red
        }
    }

    static func note(peak: Float, for track: AudioTrack) -> String? {
        MeterScale.verdict(peak: peak, for: track).map {
            styled($0, MeterScale.zone(peak) == .healthy ? .dim : .yellow)
        }
    }
}
