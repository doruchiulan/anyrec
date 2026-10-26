import AnyRecKit
import AppKit
import AVFoundation
import Observation

@MainActor
@Observable
final class WelcomeAccess {
    var screen = Permissions.screenRecordingGranted()
    var microphone = Permissions.microphoneGranted()
    var accessibility = Permissions.accessibilityGranted()
    var notifications = false

    var allGranted: Bool { screen && microphone && accessibility && notifications }

    func refresh() async {
        screen = Permissions.screenRecordingGranted()
        microphone = Permissions.microphoneGranted()
        accessibility = Permissions.accessibilityGranted()
        notifications = await NotificationPermission.granted() == true
    }

    func request(_ permission: Item, controller: RecordingController) async {
        switch permission {
        case .screen:
            await controller.requestScreenRecording()
            NSWorkspace.shared.open(Permission.screenRecording.settingsURL)
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                NSWorkspace.shared.open(Permission.microphone.settingsURL)
            } else {
                _ = await Permissions.requestMicrophone()
            }
        case .accessibility:
            Permissions.requestAccessibility()
            NSWorkspace.shared.open(Permission.accessibility.settingsURL)
        case .notifications:
            if !(await NotificationPermission.request()) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
            }
        }
        await refresh()
    }

    func granted(_ permission: Item) -> Bool {
        switch permission {
        case .screen: screen
        case .microphone: microphone
        case .accessibility: accessibility
        case .notifications: notifications
        }
    }

    enum Item: String, CaseIterable, Identifiable {
        case screen = "Screen recording"
        case microphone = "Microphone"
        case accessibility = "Accessibility"
        case notifications = "Notifications"

        var id: Self { self }
        var symbol: String {
            switch self {
            case .screen: "macwindow"
            case .microphone: "mic"
            case .accessibility: "accessibility"
            case .notifications: "bell"
            }
        }
        var detail: String {
            switch self {
            case .screen: "Record the window or display you choose."
            case .microphone: "Include your voice in the recording."
            case .accessibility: "Track your microphone’s mute status so your voice is only included while you’re unmuted in the call."
            case .notifications: "Get a reminder to record when a call starts."
            }
        }
    }
}
