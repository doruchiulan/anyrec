import SwiftUI
import AnyRecKit

/// The live recording, compact: a red dot, the clock and what is being recorded on one
/// line with a level bar per track, then a full-width Stop Recording button — a labelled
/// push button, not an icon, so nobody has to guess where to click. A note says when the
/// call cannot hear the microphone, and another when frames are being dropped; nothing
/// else is shown, because the panel is opened to check and to stop.
struct RecordingPanel: View {
    @Bindable var controller: RecordingController

    var body: some View {
        let _ = controller.tick

        if let session = controller.session {
            let muted = session.configuration.microphone != nil && session.callHearsMicrophone == false
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                        .accessibilityLabel("Recording")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Wording.clock(session.elapsed))
                            .font(.title2).monospacedDigit()
                        Text(Wording.recordingLine(
                            title: session.target.describing, app: app(of: session),
                            audioOnly: !session.configuration.video, remaining: session.remaining))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    LevelBars(tracks: tracks(of: session), levels: session.levels, microphoneMuted: muted)
                }
                Button(role: .destructive) {
                    Task { await controller.stop() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                        Text(controller.phase == .stopping ? "Finishing…" : "Stop Recording")
                        if controller.phase != .stopping {
                            Text("⌘.").foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(".")
                .disabled(controller.phase == .stopping)
                if muted {
                    Note(Wording.mutedInCall(app: app(of: session)))
                }
                if let dropped = droppedFrames(session) {
                    Note(Wording.droppedFrames(dropped)).foregroundStyle(.orange)
                }
            }
        }
    }

    private func app(of session: RecordingSession) -> String? {
        session.target.bundleID.flatMap { id in CallApps.known.first { $0.bundleID == id }?.name }
    }

    private func droppedFrames(_ session: RecordingSession) -> Int? {
        guard session.configuration.video else { return nil }
        let progress = session.progress()
        return DropRate.worthReporting(progress.droppedSamples, of: progress.screenFrames) ? progress.droppedSamples : nil
    }

    private func tracks(of session: RecordingSession) -> [AudioTrack] {
        AudioTrack.allCases.filter {
            $0 == .systemAudio
                ? session.configuration.systemAudio
                : session.configuration.microphone != nil
        }
    }
}

/// A short line in a light rounded box under the Stop button.
private struct Note: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}
