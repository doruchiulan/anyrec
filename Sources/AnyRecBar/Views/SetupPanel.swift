import SwiftUI
import AnyRecKit

/// The settings, and the button that starts a recording from them.
struct SetupPanel: View {
    @Bindable var controller: RecordingController

    var body: some View {
        if controller.canSeeScreen {
            VStack(alignment: .leading, spacing: 12) {
                Form {
                    capture
                    microphone
                    Toggle("System audio", isOn: $controller.configuration.systemAudio)
                    Toggle("Merge into call.mp4", isOn: $controller.configuration.mux)
                    transcribe
                    stopAfter
                }
                if let advisory = controller.advisory {
                    Notice(Wording.advisory(advisory))
                }
                if let failure = controller.failure {
                    Notice(failure, level: .error)
                }
                start
            }
        } else {
            PermissionPanel()
        }
    }

    private var capture: some View {
        Picker("Record", selection: $controller.configuration.capture) {
            /// Recording the wrong window is worse than recording nothing, so nothing
            /// is picked until someone picks it.
            Text("Nothing picked yet").tag(CaptureChoice?.none)
            ForEach(controller.catalogue?.sections ?? [], id: \.title) { section in
                Section(section.title) {
                    ForEach(section.entries, id: \.choice) { entry in
                        Text(entry.choice.label).tag(CaptureChoice?.some(entry.choice))
                    }
                }
            }
        }
    }

    private var microphone: some View {
        Picker("Microphone", selection: $controller.configuration.microphone) {
            Text("Off").tag(AudioInputDevice?.none)
            ForEach(controller.microphones, id: \.self) { device in
                Text(Wording.microphone(device)).tag(AudioInputDevice?.some(device))
            }
        }
    }

    private var transcribe: some View {
        Picker("Transcript", selection: $controller.configuration.transcribe) {
            ForEach(RecordingConfiguration.transcribeChoices, id: \.self) { engine in
                Text(Wording.engine(engine, controller.readiness)).tag(engine)
            }
        }
    }

    private var stopAfter: some View {
        Picker("Stop", selection: $controller.configuration.stopAfter) {
            ForEach(RecordingConfiguration.stopChoices, id: \.self) { choice in
                Text(Wording.stopAfter(choice)).tag(choice)
            }
        }
    }

    private var start: some View {
        Button("Start Recording") {
            Task { await controller.start() }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!controller.canStart)
        .frame(maxWidth: .infinity)
    }
}
