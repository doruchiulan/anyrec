import AppKit
import UserNotifications
import AnyRecKit

/// The offer to record, as a notification with Record and Record Audio Only buttons.
/// Pressing one — or the notification itself, which is Record — is the same as pressing
/// the panel's button of that name: the picker opens and the next click starts the
/// recording. One offer per call, withdrawn when the
/// call ends.
///
/// The same center also says when a call was recorded automatically, with a Stop button
/// that does what Stop Recording does. It is withdrawn when that recording ends.
///
/// Notifications need their own grant, asked for the first time there is something
/// to say rather than at launch, so the dialog arrives with its reason in view.
@MainActor
final class CallNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let category = "call"
    nonisolated static let record = "record"
    nonisolated static let recordAudioOnly = "record-audio-only"
    nonisolated static let recording = "recording"
    nonisolated static let stop = "stop"

    /// Whether to keep the picture: false for Record Audio Only.
    private let onRecord: (Bool) -> Void
    private let onStop: () -> Void
    /// `UNUserNotificationCenter` aborts outside a bundle, and `swift run` is outside one.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil

    init(onRecord: @escaping (Bool) -> Void, onStop: @escaping () -> Void) {
        self.onRecord = onRecord
        self.onStop = onStop
        super.init()
        guard let center else { return }
        center.delegate = self
        let record = UNNotificationAction(
            identifier: Self.record, title: "Record", options: [.foreground])
        let audioOnly = UNNotificationAction(
            identifier: Self.recordAudioOnly, title: "Record Audio Only", options: [.foreground])
        let stop = UNNotificationAction(identifier: Self.stop, title: "Stop Recording", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category, actions: [record, audioOnly], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.recording, actions: [stop], intentIdentifiers: []),
        ])
    }

    func offer(_ app: CallApp) {
        let words = Wording.callOffer(app)
        post(words.title, words.body, category: Self.category, level: .timeSensitive)
    }

    func announce(_ app: CallApp, video: Bool) {
        let words = Wording.automaticRecordingStarted(app, video: video)
        post(words.title, words.body, category: Self.recording, level: .active)
    }

    func withdrawAnnouncement() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.recording])
        center?.removePendingNotificationRequests(withIdentifiers: [Self.recording])
    }

    /// Each category is one notification, replaced rather than stacked.
    private func post(_ title: String, _ body: String, category: String, level: UNNotificationInterruptionLevel) {
        guard let center else { return }
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            content.interruptionLevel = level
            try? await center.add(
                UNNotificationRequest(identifier: category, content: content, trigger: nil))
        }
    }

    func withdraw() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.category])
        center?.removePendingNotificationRequests(withIdentifiers: [Self.category])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        if response.notification.request.content.categoryIdentifier == Self.recording {
            guard response.actionIdentifier == Self.stop else { return }
            await MainActor.run { onStop() }
            return
        }
        let video: Bool
        switch response.actionIdentifier {
        case Self.record, UNNotificationDefaultActionIdentifier: video = true
        case Self.recordAudioOnly: video = false
        default: return
        }
        await MainActor.run {
            NSApplication.shared.activate(ignoringOtherApps: true)
            onRecord(video)
        }
    }

    /// Shown even while the panel is open: the panel does not say a call began.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
