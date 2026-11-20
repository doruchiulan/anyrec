import AnyRecKit
import SwiftUI

struct MeetingSyncButton: View {
    let team: TeamLibrary
    let entry: LibraryEntry
    @State private var moving: URL?
    @State private var removing = false

    /// Whether the synced copy is up in the cloud, read off the main thread: a menu is
    /// built in a view's body, where no file system belongs.
    @State private var uploaded: Bool?

    var body: some View {
        Menu {
            /// Where things stand first, so a recording that is not synced never reads as one,
            /// and one that is shows that its shared copy is current.
            if let current = team.publication(entry) {
                Text(Wording.syncedTo(current.folder))
                Text(Wording.syncStatus(failure: team.snapshot?.failures[entry.directory], restored: current.restored, uploaded: uploaded))
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
            synced: team.publication(entry)?.directory, failure: team.snapshot?.failures[entry.directory],
            restored: team.publication(entry)?.restored, defaultFolder: team.snapshot?.state.lastFolder, uploaded: uploaded
        ))
        .disabled(team.busy || entry.media == nil || team.snapshot == nil)
        .help(label)
        /// An icon, like the toolbar's other items: the label truncated to "Sync…" in a
        /// window of ordinary width. The state is in the menu, the header's cloud and the help.
        .labelStyle(.iconOnly)
        .task(id: team.publication(entry)?.directory) {
            guard team.publication(entry) != nil else { uploaded = nil; return }
            repeat {
                let publication = team.publication(entry)
                uploaded = await Task.detached(priority: .utility) { [entry] in
                    RecordingCloud.isAvailable(for: entry, publication: publication)
                }.value
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            } while !Task.isCancelled
        }
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
        let failure: String?
        let restored: Date?
        let defaultFolder: URL?
        let uploaded: Bool?
    }

    /// The state at a glance. Synced is a filled cloud in the accent colour, the same as the
    /// list's badge; not synced is the plain outline of the action, Sync. Both used to be
    /// outlines a mark apart, and "cloud with an arrow up" read as uploaded when it meant
    /// "not synced yet".
    private var symbol: String {
        guard team.publication(entry) != nil else { return "icloud.and.arrow.up" }
        if team.snapshot?.failures[entry.directory] != nil { return "exclamationmark.icloud.fill" }
        return uploaded == false ? "arrow.clockwise.icloud.fill" : "checkmark.icloud.fill"
    }

    /// A toolbar draws its items' images as templates, in the text colour, whatever
    /// SwiftUI tint they carry: a synced cloud only shows blue as a coloured, non-template
    /// image. Not synced stays a template, so it follows the toolbar like the other items.
    private var icon: Image {
        let colour: NSColor? = team.publication(entry) == nil ? nil
            : team.snapshot?.failures[entry.directory] != nil ? .systemOrange : .controlAccentColor
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
        if team.snapshot?.failures[entry.directory] != nil { return "Sync needs attention" }
        if let current = team.publication(entry) { return Wording.syncedTo(current.folder) }
        if let folder = team.snapshot?.state.lastFolder { return "Sync to " + Wording.syncFolder(folder) }
        return "Sync…"
    }
}
