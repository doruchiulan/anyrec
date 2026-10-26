import AnyRecKit
import SwiftUI

struct LibraryRow: View {
    let entry: LibraryEntry
    let working: Bool
    let progress: String?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            /// The margin Notes keeps for a shared note's badge carries what a recording
            /// still needs: being worked on, or voices waiting for names.
            /// Always there, badge or not, so every row's text starts at the same edge.
            ZStack {
                Color.clear
                if working {
                    Image(systemName: "hourglass").help(progress ?? "Working…")
                } else if entry.unnamedVoices > 0 {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .help(Wording.unnamed(entry.unnamedVoices))
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(Wording.rowTitle(of: entry)).font(.headline).lineLimit(1)
                HStack(spacing: 8) {
                    Text(Wording.rowDate(entry.started)).monospacedDigit().lineLimit(1).fixedSize()
                    Text(progress ?? entry.preview ?? Wording.size(entry.bytes))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Label(Wording.rowSource(of: entry), systemImage: entry.info?.isCall == true ? "phone" : "record.circle")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if entry.video != nil { RowThumbnail(entry: entry) }
        }
        .padding(.vertical, 6)
    }
}

/// A still from the video, made once and kept beside the tracks.
private struct RowThumbnail: View {
    let entry: LibraryEntry
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.05)
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
        .task(id: entry.directory) {
            if let url = await Thumbnail.of(entry) { image = NSImage(contentsOf: url) }
        }
    }
}
