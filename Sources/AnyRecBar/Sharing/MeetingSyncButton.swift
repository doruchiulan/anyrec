import AnyRecKit
import SwiftUI

struct MeetingSyncButton: View {
    let team: TeamLibrary
    let entry: LibraryEntry
    @State private var moving: URL?
    @State private var removing = false

    private var failure: String? { team.failure(entry) }
    private var upload: SharedUpload? { team.upload(entry) }
    private var preparing: Bool { team.isPreparing(entry) }
    private var uploadFailed: Bool { if case .failed? = upload { true } else { false } }
    private var status: String {
        Wording.syncStatus(failure: failure, restored: team.publication(entry)?.restored, preparing: preparing, upload: upload)
    }

    var body: some View {
        Menu {
            /// Where things stand first, so a recording that is not synced never reads as one,
            /// and one that is shows that its shared copy is current.
            if let current = team.publication(entry) {
                Text(Wording.syncedTo(current.folder))
                Text(status)
                if !preparing, let note = Wording.sharedTracks(call: current.sharesTracks, microphone: current.sharesMicrophone) { Text(note) }
                if failure != nil { Button("Try Again") { team.retry(entry) } }
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([current.directory]) }
                Button("Move to…") {
                    if let folder = team.choose("Choose new destination", message: Wording.viewOnlyTip), folder != current.folder { moving = folder }
                }
                Button("Stop Syncing…", role: .destructive) { removing = true }
            } else {
                Text(Wording.syncedTo(nil))
                Divider()
                if let folder = team.snapshot?.state.lastFolder {
                    Button("Sync to " + Wording.syncFolder(folder)) { team.publish(entry, to: folder) }
                }
                Button("Choose Folder…") { team.publish(entry) }
            }
        } label: {
            Label {
                Text(label)
            } icon: {
                icon
            }
        } primaryAction: {
            if let current = team.publication(entry) {
                NSWorkspace.shared.activateFileViewerSelecting([current.directory])
            } else { team.publish(entry, to: team.snapshot?.state.lastFolder) }
        }
        /// A toolbar menu is made into an `NSMenu` once and its items are not rebuilt when
        /// what they read changes: the icon followed a sync while the menu still said "Not
        /// synced". A new identity whenever the state changes builds it again.
        .id(MenuState(
            synced: team.publication(entry)?.directory, status: status, defaultFolder: team.snapshot?.state.lastFolder
        ))
        .disabled(team.syncing.contains(entry.directory.standardizedFileURL) || entry.media == nil || team.snapshot == nil)
        .help(team.publication(entry) == nil ? label : "\(label). \(status)")
        /// An icon, like the toolbar's other items: the label truncated to "Sync…" in a
        /// window of ordinary width. The state is in the menu, the header's cloud and the help.
        .labelStyle(.iconOnly)
        .confirmationDialog("Move from \(team.publication(entry)?.folder.lastPathComponent ?? "") to \(moving?.lastPathComponent ?? "")?",
                            isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }), presenting: moving) { folder in
            Button("Move") { team.publish(entry, to: folder) }
        }
        .confirmationDialog("Stop syncing to \(team.publication(entry)?.folder.lastPathComponent ?? "the shared folder")?",
                            isPresented: $removing) {
            Button("Stop Syncing", role: .destructive) { team.remove(entry) }
        } message: { Text("The shared copy is removed. Colleagues who added it to their library lose it; copies they made stay. Your recording stays as it is.") }
    }

    private struct MenuState: Hashable {
        let synced: URL?
        let status: String
        let defaultFolder: URL?
    }

    /// The state at a glance. Synced is a filled cloud in the accent colour, the same as the
    /// list's badge; not synced is the plain outline of the action, Sync. Both used to be
    /// outlines a mark apart, and "cloud with an arrow up" read as uploaded when it meant
    /// "not synced yet".
    private var symbol: String {
        guard team.publication(entry) != nil else { return preparing ? "arrow.clockwise.icloud.fill" : "icloud.and.arrow.up" }
        if failure != nil || uploadFailed { return "exclamationmark.icloud.fill" }
        if preparing { return "arrow.clockwise.icloud.fill" }
        if case .uploading? = upload { return "arrow.clockwise.icloud.fill" }
        return "checkmark.icloud.fill"
    }

    /// A toolbar draws its items' images as templates, in the text colour, whatever
    /// SwiftUI tint they carry: a synced cloud only shows blue as a coloured, non-template
    /// image. Not synced stays a template, so it follows the toolbar like the other items.
    private var icon: Image {
        let colour: NSColor? = team.publication(entry) == nil ? nil
            : failure != nil || uploadFailed ? .systemOrange : .controlAccentColor
        /// Painted over the plain symbol rather than given a palette colour, which filled
        /// the checkmark's cut-out along with the cloud.
        guard let colour, let symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) else { return Image(systemName: symbol) }
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            colour.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return Image(nsImage: tinted)
    }

    private var label: String {
        if failure != nil || uploadFailed { return "Sync needs attention" }
        if let current = team.publication(entry) { return Wording.syncedTo(current.folder) }
        if let folder = team.snapshot?.state.lastFolder { return "Sync to " + Wording.syncFolder(folder) }
        return "Sync…"
    }
}
