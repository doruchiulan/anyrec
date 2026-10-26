import SwiftUI
import AnyRecKit

/// The live recording: how long it has been running, what it is pointed at, and a
/// meter for each track that is actually being written.
struct RecordingPanel: View {
    @Bindable var controller: RecordingController

    var body: some View {
        let _ = controller.tick

        if let session = controller.session {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Recording", systemImage: "record.circle.fill")
                        .font(.headline).foregroundStyle(.red)
                    Spacer()
                    if let left = session.remaining {
                        Text(Wording.remaining(left)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Wording.clock(session.elapsed))
                        .font(.largeTitle).monospacedDigit()
                    Text(session.target.describing).lineLimit(1).truncationMode(.middle)
                    Text(detail(session)).font(.subheadline).foregroundStyle(.secondary)
                }
                RecordingMeters(tracks: tracks(of: session), levels: session.levels)
                Button(role: .destructive) {
                    Task { await controller.stop() }
                } label: {
                    Label(controller.phase == .stopping ? "Finishing…" : "Stop Recording", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(".")
                .disabled(controller.phase == .stopping)
            }
        }
    }

    private func detail(_ session: RecordingSession) -> String {
        let progress = session.progress()
        let size = "\(session.target.width)×\(session.target.height)"
        let dropped = DropRate.worthReporting(progress.droppedSamples, of: progress.screenFrames)
        return "\(size) · \(session.configuration.fps) fps"
            + (dropped ? " · \(progress.droppedSamples) frames dropped" : "")
    }

    private func tracks(of session: RecordingSession) -> [AudioTrack] {
        AudioTrack.allCases.filter {
            $0 == .systemAudio
                ? session.configuration.systemAudio
                : session.configuration.microphone != nil
        }
    }
}
