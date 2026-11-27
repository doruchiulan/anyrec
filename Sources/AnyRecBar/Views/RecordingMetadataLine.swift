import AnyRecKit
import SwiftUI

struct RecordingMetadataLine: View {
    let entry: LibraryEntry
    let mark: CloudMark?
    var note: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Text(Wording.meta(of: entry))
            if let mark {
                /// The list's badge, so a recording looks the same everywhere.
                Image(systemName: mark.symbol)
                    .foregroundStyle(mark == .failed ? Color.orange : .accentColor)
                    .accessibilityLabel(mark.label)
                    .help(mark.label)
            }
            if let note { Text(note).monospacedDigit() }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

enum RecordingCloud {
    static func linkFile(for entry: LibraryEntry) -> URL {
        RecordingLayout(directory: entry.directory).url("cloud-media-link.txt")
    }

    /// The one cloud copy a recording has: the synced one.
    static func syncedMedia(for entry: LibraryEntry, publication: MeetingPublication?) -> URL? {
        publication?.directory.appendingPathComponent(entry.audioOnly ? "Recording.m4a" : "Recording.mp4")
    }
}
