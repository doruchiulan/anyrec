#if ANYREC_WEBSITE_DEMO
import AnyRecKit
import SwiftUI

struct DemoCall: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Sketch review", systemImage: "phone.fill")
                .font(.headline).foregroundStyle(.white)
            HStack(spacing: 10) {
                tile("RV", "Robin Vale", color: Color(red: 0.22, green: 0.40, blue: 0.42))
                tile("JL", "Jules Lake", color: Color(red: 0.32, green: 0.32, blue: 0.51))
            }
        }
        .padding(18)
        .background(Color(red: 0.12, green: 0.14, blue: 0.19), in: RoundedRectangle(cornerRadius: 14))
    }

    private func tile(_ initials: String, _ name: String, color: Color) -> some View {
        ZStack(alignment: .bottomLeading) {
            Text(initials).font(.system(size: 30, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(name).font(.caption.weight(.medium)).padding(10)
        }
        .foregroundStyle(.white)
        .background(color, in: RoundedRectangle(cornerRadius: 9))
        .frame(height: 106)
    }
}

struct DemoRecording: View {
    let started: Date
    let video: Bool
    let stop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: started, by: 0.12)) { tick in
            let elapsed = max(0, tick.date.timeIntervalSince(started))
            VStack(alignment: .leading, spacing: 10) {
                RecordingControls(elapsed: elapsed, detail: Wording.recordingLine(
                    title: "Sketch review", app: "Slack", audioOnly: !video, remaining: nil),
                    meters: meters(elapsed), stop: stop)
                Divider()
                MenuRow("Open AnyRec", action: stop)
            }
            .padding(12)
            .frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func meters(_ elapsed: TimeInterval) -> LevelBars {
        let monitor = LevelMonitor()
        for (track, offset) in [(AudioTrack.systemAudio, 0.0), (.microphone, 1.8)] {
            let peak = Float(-20 + 10 * sin(elapsed * 2.6 + offset))
            monitor.record(AudioLevel(peak: peak, rms: peak - 5), for: track)
        }
        return LevelBars(tracks: AudioTrack.allCases, levels: monitor, microphoneMuted: false)
    }
}
#endif
