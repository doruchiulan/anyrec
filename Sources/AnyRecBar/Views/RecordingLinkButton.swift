import AnyRecKit
import SwiftUI

struct RecordingLinkButton: View {
    let entry: LibraryEntry
    let publications: [MeetingPublication]
    @State private var editing = false

    var body: some View {
        Button("Recording link…", systemImage: "link") { editing = true }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .sheet(isPresented: $editing) {
                let file = RecordingCloud.linkFile(for: entry)
                RecordingLinkEditor(link: DraftRecordingLink.read(file), copies: copies) { link in
                    try DraftRecordingLink.save(link, at: file)
                    editing = false
                }
            }
    }
    /// The synced copy, the one cloud copy a recording has.
    private var copies: [URL] { publications.compactMap { RecordingCloud.syncedMedia(for: entry, publication: $0) } }
}
