import AppKit
import SwiftUI
import AnyRecKit

/// Without Screen Recording there is nothing to list and nothing to record, so the
/// panel says so rather than offering an empty picker. The microphone is not asked for
/// here — it is requested when a recording that wants one starts.
struct PermissionPanel: View {
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
    }
}
