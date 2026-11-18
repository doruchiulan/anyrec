import AnyRecKit
import AppKit
import SwiftUI

/// The recording page's Share button: prepares what leaves the Mac — the video with its
/// captions and summary inside, `Summary.md` and `Transcript.md` (`RecordingShare`) — then
/// opens the system's share menu on all three. OneDrive installs no share extension, so it
/// never appears there by itself; "Save to OneDrive" and "Save to iCloud Drive" are added
/// for each synced folder found on this Mac (`CloudFolder`), and copy the set into it for
/// that service's app to upload. File › Share… and the list's Share… reach the same button
/// through `RecordingController.shareRequest`.
struct ShareButton: View {
    @Bindable var controller: RecordingController
    let entry: LibraryEntry
    @State private var anchor = Anchor()
    @State private var preparing = false

    var body: some View {
        Button {
            share()
        } label: {
            if preparing {
                ProgressView().controlSize(.small)
            } else {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .help("Share the video, summary and transcript")
        .disabled(preparing || entry.media == nil)
        .background(AnchorView(anchor: anchor))
        .onChange(of: controller.shareRequest) { _, request in takeRequest(request) }
        /// Share… on a recording that was not open selects it and asks in the same turn,
        /// before this button exists to see the change.
        .onAppear { takeRequest(controller.shareRequest) }
    }

    private func takeRequest(_ request: URL?) {
        guard request == entry.directory else { return }
        controller.shareRequest = nil
        share()
    }

    private func share() {
        guard !preparing else { return }
        preparing = true
        let directory = entry.directory
        Task {
            defer { preparing = false }
            do {
                let set = try await Task.detached(priority: .userInitiated) {
                    try await RecordingShare.prepare(directory)
                }.value
                anchor.present(set, controller: controller)
            } catch {
                controller.shareFailed(error.localizedDescription)
            }
        }
    }

    /// The button's AppKit view, which the share menu hangs from, and the menu's delegate,
    /// kept alive while the menu is open.
    @MainActor
    final class Anchor {
        weak var view: NSView?
        private var delegate: PickerDelegate?

        func present(_ set: RecordingShare.Set, controller: RecordingController) {
            guard let view, view.window != nil else { return }
            let delegate = PickerDelegate(set: set, controller: controller)
            self.delegate = delegate
            let picker = NSSharingServicePicker(items: set.files)
            picker.delegate = delegate
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    private struct AnchorView: NSViewRepresentable {
        let anchor: Anchor
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            anchor.view = view
            return view
        }
        func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
    }

    /// Puts "Save to OneDrive" / "Save to iCloud Drive" above the system's services.
    final class PickerDelegate: NSObject, NSSharingServicePickerDelegate {
        let set: RecordingShare.Set
        weak var controller: RecordingController?

        init(set: RecordingShare.Set, controller: RecordingController) {
            self.set = set
            self.controller = controller
        }

        func sharingServicePicker(
            _ picker: NSSharingServicePicker, sharingServicesForItems items: [Any],
            proposedSharingServices proposed: [NSSharingService]
        ) -> [NSSharingService] {
            let set = set
            let saves = CloudFolder.available().map { folder in
                NSSharingService(title: Wording.saveTo(folder), image: Self.icon(for: folder), alternateImage: nil) {
                    [weak controller] in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let saved = try folder.save(set)
                            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                        } catch {
                            let message = "Couldn't save to \(folder.name): \(error.localizedDescription)"
                            DispatchQueue.main.async { controller?.shareFailed(message) }
                        }
                    }
                }
            }
            return saves + proposed
        }

        private static func icon(for folder: CloudFolder) -> NSImage {
            switch folder.service {
            case .oneDrive:
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.OneDrive") {
                    return NSWorkspace.shared.icon(forFile: app.path)
                }
                return NSImage(systemSymbolName: "cloud", accessibilityDescription: nil) ?? NSImage()
            case .iCloudDrive:
                return NSImage(systemSymbolName: "icloud", accessibilityDescription: nil) ?? NSImage()
            }
        }
    }
}
