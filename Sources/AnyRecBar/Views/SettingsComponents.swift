import SwiftUI

struct SettingsPane<Content: View>: View {
    var scrollable = false
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(!scrollable)
            .frame(height: scrollable ? 620 : nil)
            .fixedSize(horizontal: false, vertical: !scrollable)
    }
}

struct SetupControl: View {
    @Bindable var controller: RecordingController
    let target: SetupTarget
    let size: String
    let start: () -> Void

    var body: some View {
        if controller.setupTarget == target, let progress = controller.setupProgress {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(progress).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Button("Download (\(size))", action: start)
                .disabled(controller.isSettingUp)
        }
    }
}

struct Status: View {
    let text: String
    var ready = false

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: ready ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(ready ? .green : .secondary)
        }
        .foregroundStyle(.secondary)
    }
}
