import AppKit
import UserNotifications
import AnyRecKit

/// The offer to record, as a notification with a Record button. Pressing it — or the
/// notification itself — is the same as pressing the panel's button: the picker opens
/// and the next click starts the recording. One offer per call, withdrawn when the
/// call ends.
///
/// Notifications need their own grant, asked for the first time there is something
/// to say rather than at launch, so the dialog arrives with its reason in view.
@MainActor
final class CallNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let category = "call"
    nonisolated static let record = "record"

    private let onRecord: () -> Void
    /// `UNUserNotificationCenter` aborts outside a bundle, and `swift run` is outside one.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil

    init(onRecord: @escaping () -> Void) {
        self.onRecord = onRecord
        super.init()
        guard let center else { return }
        center.delegate = self
        let action = UNNotificationAction(
            identifier: Self.record, title: "Record", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category, actions: [action], intentIdentifiers: [])
        ])
    }

    func offer(_ app: CallApp) {
        guard let center else { return }
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            else { return }
            let content = UNMutableNotificationContent()
            content.title = Wording.callOffer(app).title
            content.body = Wording.callOffer(app).body
            content.categoryIdentifier = Self.category
            content.interruptionLevel = .timeSensitive
            try? await center.add(
                UNNotificationRequest(identifier: Self.category, content: content, trigger: nil))
        }
    }

    func withdraw() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.category])
        center?.removePendingNotificationRequests(withIdentifiers: [Self.category])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.record
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return }
        await MainActor.run {
            NSApplication.shared.activate(ignoringOtherApps: true)
            onRecord()
        }
    }

    /// Shown even while the panel is open: the panel does not say a call began.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
