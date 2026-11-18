import SwiftUI
import AnyRecKit

/// One small vertical bar per recorded track, beside the clock. Green while the level is
/// healthy, orange only near clipping, grey when quiet, silent or muted — the zones are
/// `MeterScale`'s. They replace `NSLevelIndicator`, whose warning colour covered the whole
/// bar from 80% of its range: −12 dB on this scale, which normal speech passes, so every
/// call read as a warning.
struct LevelBars: View {
    struct Bar: Identifiable, Equatable {
        let track: AudioTrack
        let fraction: Double
        let tint: Tint
        var id: AudioTrack { track }
    }

    enum Tint: Equatable {
        case healthy, hot, quiet, muted
    }

    let bars: [Bar]

    /// Read once per redraw, so a new level on the same monitor draws a new bar.
    init(tracks: [AudioTrack], levels: LevelMonitor, microphoneMuted: Bool) {
        bars = tracks.map { track in
            Self.bar(track, peak: levels.level(for: track).peak, muted: track == .microphone && microphoneMuted)
        }
    }

    static func bar(_ track: AudioTrack, peak: Float, muted: Bool) -> Bar {
        let fraction = Double(MeterScale.fraction(peak))
        guard !muted else { return Bar(track: track, fraction: min(fraction, 0.1), tint: .muted) }
        let tint: Tint = switch MeterScale.zone(peak) {
        case .hot: .hot
        case .healthy: .healthy
        case .faint, .silent: .quiet
        }
        return Bar(track: track, fraction: fraction, tint: tint)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(bars) { bar in
                ZStack(alignment: .bottom) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color(bar.tint))
                        .frame(height: max(4, 28 * bar.fraction))
                }
                .frame(width: 5, height: 28)
                .accessibilityElement()
                .accessibilityLabel(bar.track == .systemAudio ? "Call audio level" : "Microphone level")
                .accessibilityValue(Wording.level(bar.tint))
            }
        }
        .animation(.linear(duration: 0.1), value: bars)
    }

    private func color(_ tint: Tint) -> Color {
        switch tint {
        case .healthy: .green
        case .hot: .orange
        case .quiet, .muted: .secondary
        }
    }
}
