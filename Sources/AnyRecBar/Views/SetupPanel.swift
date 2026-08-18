import SwiftUI
import AnyRecKit

/// The settings, and the button that starts a recording from them. System audio and the
/// merge are on and not shown: they are what the tool is for, and `anyrec record` carries
/// a flag for anyone who wants a recording without them.
struct SetupPanel: View {
    @Bindable var controller: RecordingController

    var body: some View {
        if controller.canSeeScreen {
            VStack(alignment: .leading, spacing: 12) {
                Form {
                    microphone
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
            PermissionPanel(controller: controller)
        }
    }

    private var microphone: some View {
        Picker("Microphone", selection: $controller.microphone) {
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

    /// Choosing what to record is the first half of this button, not a row above it.
    private var start: some View {
        Button("Choose a Window & Record") {
            controller.pickAndStart()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!controller.canStart)
        .frame(maxWidth: .infinity)
    }
}
