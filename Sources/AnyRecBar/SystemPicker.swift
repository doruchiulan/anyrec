import AnyRecKit
import Foundation
import ScreenCaptureKit

/// macOS's own content picker, which lights each window up as you move across the screen.
/// A list of titles cannot tell two "Meet — Meeting" windows apart; pointing at one can.
///
/// It is offered only here. The terminal picks from `CaptureCatalogue` because it has no
/// screen to point at, which is the same split as every other setting: the Kit says what
/// is recordable, each interface says how it is chosen.
@MainActor
final class SystemPicker: NSObject, SCContentSharingPickerObserver {
    private var report: ((CaptureChoice?) -> Void)?

    /// Windows and displays only. An application filter is a display recording wearing a
    /// disguise, and this app's own panel is never the thing being recorded.
    func present(_ report: @escaping (CaptureChoice?) -> Void) {
        self.report = report

        let picker = SCContentSharingPicker.shared
        let configuration = {
            var configuration = SCContentSharingPickerConfiguration()
            configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
            configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap { $0 }
            return configuration
        }()

        picker.configuration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    /// The picker's own Control Center affordance is turned off again between picks, so
    /// the only way to it is the panel's own row.
    private func finish(with choice: CaptureChoice?) {
        let picker = SCContentSharingPicker.shared
        picker.isActive = false
        picker.remove(self)
        report?(choice)
        report = nil
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor in finish(with: await PickedContent.choice(from: filter)) }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in finish(with: nil) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in finish(with: nil) }
    }
}
