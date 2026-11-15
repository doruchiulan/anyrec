import AnyRecKit
import SwiftUI

struct RecordingInputSettings: View {
    @Bindable var controller: RecordingController

    var body: some View {
        Picker("Microphone", selection: $controller.microphoneChoice) {
            Text(Wording.systemDefaultMicrophone(controller.microphones.first(where: \.isDefault)))
                .tag(MicrophoneChoice.systemDefault)
            Text("Off").tag(MicrophoneChoice.off)
            Divider()
            ForEach(controller.microphones, id: \.self) { device in
                Text(Wording.microphone(device)).tag(MicrophoneChoice.device(device))
            }
        }
        Picker("Stop recording", selection: $controller.configuration.stopAfter) {
            ForEach(RecordingConfiguration.stopChoices, id: \.self) { choice in
                Text(Wording.stopAfter(choice)).tag(choice)
            }
        }
    }
}
