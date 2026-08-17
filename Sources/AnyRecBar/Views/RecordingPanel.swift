import SwiftUI
import AnyRecKit

/// The live recording: how long it has been running, what it is pointed at, and a
/// meter for each track that is actually being written.
struct RecordingPanel: View {
    @Bindable var controller: RecordingController

    var body: some View {
        /// Read so the clock and the meters redraw on every tick.
        let _ = controller.tick

        if let session = controller.session {
            VStack(alignment: .leading, spacing: 12) {
                header(session)
                ForEach(tracks(of: session), id: \.self) { track in
                    LevelMeter(track: track, levels: session.levels)
                }
                folder(session)
                stop
            }
        }
    }

    private func header(_ session: RecordingSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                Text(Wording.clock(session.elapsed))
                    .font(.title2.monospacedDigit())
                Spacer()
                if let left = session.remaining {
                    Text(Wording.remaining(left))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(session.target.describing)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail(session))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func detail(_ session: RecordingSession) -> String {
        let progress = session.progress()
        let size = "\(session.target.width)×\(session.target.height)"
        let dropped = DropRate.worthReporting(progress.droppedSamples, of: progress.screenFrames)
        return "\(size) · \(session.configuration.fps) fps · \(progress.screenFrames) frames"
            + (dropped ? " · \(progress.droppedSamples) dropped" : "")
    }

    private func tracks(of session: RecordingSession) -> [AudioTrack] {
        AudioTrack.allCases.filter {
            $0 == .systemAudio
                ? session.configuration.systemAudio
                : session.configuration.microphone != nil
        }
    }

    private func folder(_ session: RecordingSession) -> some View {
        Text(session.plan.directory.lastPathComponent)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var stop: some View {
        Button(controller.phase == .stopping ? "Finishing…" : "Stop") {
            Task { await controller.stop() }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)
        .disabled(controller.phase == .stopping)
        .frame(maxWidth: .infinity)
    }
}
