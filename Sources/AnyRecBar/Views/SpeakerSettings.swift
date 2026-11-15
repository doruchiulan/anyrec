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
                        RememberedPerson(controller: controller, person: person)
                    }
                }
            }
        }
    }
}

/// One remembered person: how many voiceprints they have, where each came from, and a way
/// to remove one that was filed by a wrong name, or forget the person.
private struct RememberedPerson: View {
    @Bindable var controller: RecordingController
    let person: VoiceLibrary.Person

    var body: some View {
        DisclosureGroup {
            ForEach(Array(person.prints.indices), id: \.self) { index in
                let origin = person.origin(ofPrint: index)
                LabeledContent(Wording.printOrigin(origin, number: index + 1,
                                                   title: controller.recordingTitle(folder: origin?.recording))) {
                    Button("Remove") { controller.removePrint(at: index, from: person.name) }
                        .help(Wording.removePrintHelp)
                }
            }
        } label: {
            LabeledContent {
                Button("Forget") { controller.forget(person.name) }
            } label: {
                Text(person.name)
                Text(Wording.person(person))
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
