import AnyRecKit
import SwiftUI

struct MeetingSyncButton: View {
    let team: TeamLibrary
    let entry: LibraryEntry
    @State private var removing: MeetingPublication?

    private var copies: [MeetingPublication] { team.copies(entry) }
    private var failure: String? { team.failure(entry) }
    private var upload: SharedUpload? { team.upload(entry) }
    private var preparing: Bool { team.isPreparing(entry) }
    private var uploadFailed: Bool { if case .failed? = upload { true } else { false } }
    private var status: String {
        Wording.syncStatus(failure: failure, restored: copies.compactMap(\.restored).max(), preparing: preparing, upload: upload)
    }

    private func status(_ copy: MeetingPublication) -> String {
        Wording.syncStatus(failure: team.failure(copy), restored: copy.restored, preparing: preparing, upload: team.upload(copy))
    }

    var body: some View {
        Menu {
            /// Where things stand first, so a recording that is not synced never reads as one,
            /// and one that is shows that each shared copy is current.
            if copies.isEmpty {
                Text(Wording.syncedTo(nil))
            } else if copies.count == 1, let copy = copies.first {
                Text(Wording.syncedTo(copy.folder))
                details(copy)
            } else {
                Text(Wording.syncedTo(places: copies.count))
                ForEach(copies, id: \.id) { copy in
                    Menu(Wording.syncFolder(copy.folder) + " — " + status(copy)) { details(copy) }
                }
            }
            Divider()
            if let location = team.location, !copies.contains(where: { $0.folder == location }) {
                Button("Sync to " + Wording.syncFolder(location)) { team.publish(entry, to: location) }
            }
            if team.location == nil && copies.isEmpty {
                Button(Wording.chooseSyncLocation) { team.publish(entry) }
            } else {
                Button("Sync to Another Location…") { team.publish(entry) }
            }
        } label: {
            Label {
                Text(label)
            } icon: {
                icon
            }
        } primaryAction: {
            if let copy = copies.first {
                NSWorkspace.shared.activateFileViewerSelecting([copy.directory])
            } else { team.publish(entry, to: team.location) }
        }
        /// A toolbar menu is made into an `NSMenu` once and its items are not rebuilt when
        /// what they read changes: the icon followed a sync while the menu still said "Not
        /// synced". A new identity whenever the state changes builds it again.
        .id(MenuState(copies: copies.map { [$0.directory.path, status($0)] }, status: status, location: team.location))
        .disabled(team.syncing.contains(entry.directory.standardizedFileURL) || entry.media == nil || team.snapshot == nil)
        .help(copies.isEmpty ? label : "\(label). \(status)")
        /// An icon, like the toolbar's other items: the label truncated to "Sync…" in a
        /// window of ordinary width. The state is in the menu, the header's cloud and the help.
        .labelStyle(.iconOnly)
        .confirmationDialog(Wording.stopSyncing(removing.map { Wording.syncFolder($0.folder) } ?? "the shared folder"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { copy in
            Button(copies.count > 1 ? "Stop Syncing Here" : "Stop Syncing", role: .destructive) { team.remove(entry, from: copy) }
        } message: { _ in
            Text("The shared copy there is removed. Colleagues who see it there lose it; copies they made stay. Your recording stays as it is\(copies.count > 1 ? ", and stays synced to its other places" : "").")
        }
    }

    /// One shared copy: how it stands, and what can be done with it.
    @ViewBuilder private func details(_ copy: MeetingPublication) -> some View {
        Text(status(copy))
        if !preparing, let note = Wording.sharedTracks(call: copy.sharesTracks, microphone: copy.sharesMicrophone) { Text(note) }
        if team.failure(copy) != nil { Button("Try Again") { team.retry(entry, copy) } }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([copy.directory]) }
        Button(copies.count > 1 ? "Stop Syncing Here…" : "Stop Syncing…", role: .destructive) { removing = copy }
    }

    private struct MenuState: Hashable {
        let copies: [[String]]
        let status: String
        let location: URL?
    }

    /// The state at a glance. Synced is a filled cloud in the accent colour, the same as the
    /// list's badge; not synced is the plain outline of the action, Sync. Both used to be
    /// outlines a mark apart, and "cloud with an arrow up" read as uploaded when it meant
    /// "not synced yet".
    private var symbol: String {
        guard !copies.isEmpty else { return preparing ? "arrow.clockwise.icloud.fill" : "icloud.and.arrow.up" }
        if failure != nil || uploadFailed { return "exclamationmark.icloud.fill" }
        if preparing { return "arrow.clockwise.icloud.fill" }
        if case .uploading? = upload { return "arrow.clockwise.icloud.fill" }
        return "checkmark.icloud.fill"
    }

    /// A toolbar draws its items' images as templates, in the text colour, whatever
    /// SwiftUI tint they carry: a synced cloud only shows blue as a coloured, non-template
    /// image. Not synced stays a template, so it follows the toolbar like the other items.
    private var icon: Image {
        let colour: NSColor? = copies.isEmpty ? nil
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
        if copies.count == 1, let copy = copies.first { return Wording.syncedTo(copy.folder) }
        if copies.count > 1 { return Wording.syncedTo(places: copies.count) }
        if let folder = team.location { return "Sync to " + Wording.syncFolder(folder) }
        return String(Wording.chooseSyncLocation.dropLast())
    }
}
