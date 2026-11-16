import AppKit
import Observation
import Sparkle

/// AnyRec's updates, through Sparkle: the feed published with each release
/// (`SUFeedURL`, signed with the key in `SUPublicEDKey`), Check for Updates… in the app
/// menu, and a switch in Settings › General.
///
/// Nothing is checked until the owner agrees. Sparkle asks on the second launch, the
/// switch can change it any time, and Check for Updates… is always an explicit request.
/// An update never interrupts a call: one found while recording, while a call is on or
/// while background work runs is offered in the menu bar panel, not in a window over the
/// call, and an accepted update relaunches only once nothing is being recorded or saved.
/// Quitting already waits for both.
@MainActor
@Observable
final class Updates: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @ObservationIgnored private let recording: RecordingController
    @ObservationIgnored private var updater: SPUStandardUpdaterController?
    /// The version a background check found and held back, for the panel's row.
    private(set) var available: String?
    /// Mirrors Sparkle's own setting, so the switch in Settings redraws.
    private(set) var checksAutomatically = false
    @ObservationIgnored private var pendingRelaunch: (() -> Void)?

    init(recording: RecordingController) {
        self.recording = recording
        super.init()
        /// Only a bundle carries the feed and the key; `swift run` and tests have neither.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.updater = updater
        checksAutomatically = updater.updater.automaticallyChecksForUpdates
    }

    var isAvailable: Bool { updater != nil }

    func checkForUpdates() {
        available = nil
        updater?.checkForUpdates(nil)
    }

    func setChecksAutomatically(_ on: Bool) {
        updater?.updater.automaticallyChecksForUpdates = on
        checksAutomatically = updater?.updater.automaticallyChecksForUpdates ?? false
    }

    /// Recording, starting or stopping one, saving or transcribing one: no window, no relaunch.
    private var busy: Bool {
        recording.phase == .starting || recording.phase == .recording || recording.phase == .stopping
            || !recording.working.isEmpty
    }

    // MARK: Never during a call

    nonisolated func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            guard busy else { return false }
            pendingRelaunch = installHandler
            relaunchWhenIdle()
            return true
        }
    }

    /// Re-armed after each change until nothing is being recorded or saved, then the
    /// update Sparkle was told to wait with is let through.
    private func relaunchWhenIdle() {
        let idle = withObservationTracking { !busy } onChange: { [weak self] in
            Task { @MainActor in self?.relaunchWhenIdle() }
        }
        guard idle, let relaunch = pendingRelaunch else { return }
        pendingRelaunch = nil
        relaunch()
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled check's window is shown only when nothing is going on. Otherwise the
    /// panel offers it, and Check for Updates… shows it whenever the owner likes.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        MainActor.assumeIsolated { !busy && recording.callApp == nil }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        MainActor.assumeIsolated { if !handleShowingUpdate { available = version } }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { available = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { available = nil }
    }
}
