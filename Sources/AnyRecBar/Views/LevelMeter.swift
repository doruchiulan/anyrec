import SwiftUI
import AnyRecKit

/// One track's level, read off the buffers already on their way to disk. The bar fills
/// to RMS with the current peak riding on top as a marker, and the loudest peak of the
/// whole run is held beside it — the same reading the terminal's meter gives.
struct LevelMeter: View {
    let track: AudioTrack
    let levels: LevelMonitor

    private static let height: CGFloat = 6

    var body: some View {
        let level = levels.level(for: track)
        let colour = colour(for: level.peak)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(track.rawValue)
                Spacer()
                Text(MeterScale.reading(level.peak)).monospacedDigit()
                Text("max \(MeterScale.reading(levels.sessionPeak(for: track)))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(colour)
                        .frame(width: fraction(level.rms) * geometry.size.width)
                    Rectangle()
                        .fill(colour)
                        .frame(width: 2)
                        .offset(x: fraction(level.peak) * (geometry.size.width - 2))
                }
            }
            .frame(height: Self.height)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.rawValue) level")
        .accessibilityValue("\(MeterScale.reading(level.peak)) dBFS")
    }

    private func fraction(_ dBFS: Float) -> CGFloat {
        CGFloat(MeterScale.fraction(dBFS))
    }

    private func colour(for peak: Float) -> Color {
        switch MeterScale.zone(peak) {
        case .silent: .secondary
        case .faint: .yellow
        case .healthy: .green
        case .hot: .red
        }
    }
}
