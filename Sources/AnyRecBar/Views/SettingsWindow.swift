import AnyRecKit
import SwiftUI

/// The settings that do not belong in a panel you opened to press one button: the two
/// the panel leaves at their defaults, and setting a transcription engine up — which was
/// a terminal job until this existed, and so unreachable for anyone who installed only
/// the app.
struct SettingsWindow: View {
    @Bindable var controller: RecordingController

    var body: some View {
        TabView {
            GeneralSettings(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
            TranscriptionSettings(controller: controller)
                .tabItem { Label("Transcription", systemImage: "text.bubble") }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettings: View {
    @Bindable var controller: RecordingController

    var body: some View {
        Form {
            Toggle("Record system audio", isOn: $controller.configuration.systemAudio)
            Text("The audio the call plays back, as its own track.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Merge into call.mp4", isOn: $controller.configuration.mux)
            Text(
                Readiness.ffmpegInstalled
                    ? "One playable file alongside the three tracks, which are never rewritten."
                    : "Needs ffmpeg, which is not installed. Install it on the Transcription tab."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// Nothing here downloads anything until it is pressed, and what it will fetch and how
/// big that is are on the button.
private struct TranscriptionSettings: View {
    @Bindable var controller: RecordingController
    @State private var key = ""

    var body: some View {
        Form {
            Section("Engines") {
                ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                    LabeledContent(Wording.engineName(engine)) {
                        Text(Wording.engineStatus(engine, controller.readiness))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            whisper
            openAI
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var whisper: some View {
        Section("Whisper") {
            let pending = WhisperSetup.pending()
            if let progress = controller.setupProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption).lineLimit(1).truncationMode(.middle)
                }
            } else if pending.isEmpty {
                Text("Installed, with a model. Nothing to fetch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if WhisperSetup.needsHomebrew {
                Notice("Homebrew is what installs it. Get it from brew.sh, then reopen this.")
            } else {
                ForEach(pending, id: \.title) { step in
                    LabeledContent(step.title) {
                        Text(step.detail).foregroundStyle(.secondary)
                    }
                }
                Button(Wording.install(pending)) { controller.installWhisper() }
            }
            if let failure = controller.setupFailure {
                Notice(failure, level: .error)
            }
        }
    }

    @ViewBuilder private var openAI: some View {
        Section("OpenAI") {
            Text("Transcribes off your machine — both audio tracks are uploaded.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if OpenAIKey.isFromEnvironment {
                Notice("OPENAI_API_KEY is set in your environment, and is what will be used.")
            }
            /// Never drawn back once entered: a tool that records screens has to assume
            /// its own screen is being recorded.
            SecureField("sk-…", text: $key)
            Button("Save Key") {
                let entered = key
                key = ""
                Task { await controller.saveOpenAIKey(entered) }
            }
            .disabled(key.isEmpty)

            if let outcome = controller.keyOutcome {
                Notice(Wording.keyOutcome(outcome), level: Wording.wasRefused(outcome) ? .error : .advisory)
            }
        }
    }
}
