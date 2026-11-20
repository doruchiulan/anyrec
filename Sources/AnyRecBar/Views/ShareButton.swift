import AnyRecKit
import AppKit
import SwiftUI

struct FileShareAnchor: NSViewRepresentable {
    let controller: RecordingController
    let entry: LibraryEntry
    let request: URL?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard request == entry.directory else { return }
        Task { @MainActor in
            guard controller.shareRequest == entry.directory else { return }
            controller.shareRequest = nil
            do {
                let set = try await Task.detached { try await RecordingShare.prepare(entry.directory) }.value
                guard view.window != nil, controller.selectedEntry?.directory == entry.directory else { return }
                NSSharingServicePicker(items: set.files).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            } catch { controller.shareFailed(error.localizedDescription) }
        }
    }
}
