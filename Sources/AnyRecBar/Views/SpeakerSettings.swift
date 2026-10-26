import AnyRecKit
import SwiftUI

struct SpeakerSettings: View {
    @Bindable var controller: RecordingController

    var body: some View {
        Section("Speakers") {
            Toggle("Identify speakers", isOn: $controller.transcriptionOptions.identifySpeakers)
            LabeledContent {
                SpeakerModelControl(controller: controller)
            } label: {
                Text("Speaker model")
                Text("Separates voices and recognises people you've named, on this Mac.")
            }
            if let failure = controller.speakerSetupFailure { Notice(failure, level: .error) }
            if !controller.people.isEmpty {
                DisclosureGroup("Remembered voices (\(controller.people.count))") {
                    ForEach(controller.people, id: \.name) { person in
                        LabeledContent(person.name) {
                            Button("Forget") { controller.forget(person.name) }
                        }
                    }
                }
            }
        }
    }
}

struct SpeakerModelControl: View {
    @Bindable var controller: RecordingController

    var body: some View {
        if let progress = controller.speakerSetupProgress {
            HStack {
                ProgressView().controlSize(.small)
                Text(progress).foregroundStyle(.secondary)
            }
        } else if controller.speakersReady {
            Status(text: "Ready", ready: true)
        } else {
            Button("Download (\(SpeakerSetup.downloadSize))") {
                controller.transcriptionOptions.identifySpeakers = true
                controller.installSpeakers()
            }
        }
    }
}
