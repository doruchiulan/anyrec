import AppKit
import SwiftUI
import AnyRecKit

/// Without Screen Recording there is nothing to point at and nothing to record, so the
/// panel says so rather than offering a picker that cannot open. The microphone is not
/// asked for here — it is requested when a recording that wants one starts.
///
/// Asking runs on appearance, before the button is offered: macOS answers the request by
/// pointing at Settings rather than granting, and the app has to have asked before it is
/// listed there at all.
struct PermissionPanel: View {
    @Bindable var controller: RecordingController

    private let error = PermissionsError(missing: [.screenRecording], host: .application)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Screen Recording is off", systemImage: "lock.circle")
                .font(.headline)
            Text(error.relaunch)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy & Security") {
                NSWorkspace.shared.open(Permission.screenRecording.settingsURL)
            }
            .frame(maxWidth: .infinity)
        }
        .task { await controller.requestScreenRecording() }
    }
}
