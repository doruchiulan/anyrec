import AppKit
import SwiftUI
import AnyRecKit

struct RecordingMeters: View {
    private struct Reading {
        let track: AudioTrack
        let level: AudioLevel
    }

    private let readings: [Reading]

    init(tracks: [AudioTrack], levels: LevelMonitor) {
        // Snapshot before ForEach so SwiftUI sees new values instead of the same monitor reference.
        readings = tracks.map { Reading(track: $0, level: levels.level(for: $0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(readings, id: \.track) { reading in
                LevelMeter(track: reading.track, level: reading.level)
            }
        }
    }
}

struct LevelMeter: View {
    let track: AudioTrack
    let level: AudioLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(track == .systemAudio ? "Call audio" : "Microphone")
                Spacer()
                Text(reading(level.peak)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.subheadline)
            LevelIndicator(value: Double(MeterScale.fraction(level.peak)))
                .frame(height: 12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.rawValue) level")
        .accessibilityValue("\(MeterScale.reading(level.peak)) dBFS")
    }

    private func reading(_ peak: Float) -> String {
        let dB = "\(MeterScale.reading(peak)) dB"
        switch MeterScale.zone(peak) {
        case .faint: return "Quiet · \(dB)"
        case .hot: return "Too loud · \(dB)"
        case .silent, .healthy: return dB
        }
    }
}

private struct LevelIndicator: NSViewRepresentable {
    let value: Double

    func makeNSView(context: Context) -> NSLevelIndicator {
        let indicator = NSLevelIndicator()
        indicator.levelIndicatorStyle = .continuousCapacity
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.warningValue = 0.8
        indicator.criticalValue = 0.95
        indicator.isEditable = false
        return indicator
    }

    func updateNSView(_ indicator: NSLevelIndicator, context: Context) {
        indicator.doubleValue = value
    }
}
