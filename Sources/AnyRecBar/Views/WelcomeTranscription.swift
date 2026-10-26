import AnyRecKit
import SwiftUI

struct WelcomeTranscription: View {
    @Bindable var controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WelcomeCard(symbol: "waveform", title: "Parakeet", detail: "Start here for calls in its 25 supported languages.", engine: .parakeet) {
                download(.parakeet, size: ParakeetSetup.downloadSize) { controller.installParakeet() }
            }
            WelcomeCard(symbol: "globe", title: "Whisper", detail: "Choose for more languages, or to compare results.", engine: .whisper) {
                download(.whisper, size: AssetDownload.describe(
                    WhisperSetup.pending().reduce(Int64(0)) { $0 + $1.bytes })) {
                    controller.installWhisper()
                }
            }
            WelcomeCard(symbol: "person.wave.2", title: "Speaker recognition",
                        detail: "Tell voices apart and recognise people you've named. On this Mac.") {
                SpeakerModelControl(controller: controller)
            }
            if let failure = controller.speakerSetupFailure { Notice(failure, level: .error) }
            if !controller.ffmpegReady {
                WelcomeCard(symbol: "film.stack", title: "Recording tools", detail: "Combine video and audio into one playable file.") {
                    SetupControl(controller: controller, target: .ffmpeg, size: FFmpegSetup.downloadSize) {
                        controller.installFFmpeg()
                    }
                }
            }
            if let failure = controller.setupFailure { Notice(failure, level: .error) }
            Text(footer).font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private func download(
        _ engine: TranscriptionEngine, size: String, start: @escaping () -> Void
    ) -> some View {
        if controller.readiness.of(engine).isReady {
            Status(text: "Ready", ready: true)
        } else {
            SetupControl(controller: controller, target: engine == .parakeet ? .parakeet : .whisper, size: size, start: start)
        }
    }

    private var footer: String {
        controller.readiness.of(.apple).isReady
            ? "Apple transcription is already available. You can download another engine now or later in Settings."
            : "You can also set up transcription later in Settings."
    }
}
