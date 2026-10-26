import AnyRecKit
import SwiftUI

struct RecordingInputSettings: View {
    @Bindable var controller: RecordingController

    var body: some View {
        Picker("Microphone", selection: $controller.microphone) {
            Text("Off").tag(AudioInputDevice?.none)
            Divider()
            ForEach(controller.microphones, id: \.self) { device in
                Text(Wording.microphone(device)).tag(AudioInputDevice?.some(device))
            }
        }
        Picker("Stop recording", selection: $controller.configuration.stopAfter) {
            ForEach(RecordingConfiguration.stopChoices, id: \.self) { choice in
                Text(Wording.stopAfter(choice)).tag(choice)
            }
        }
    }
}
