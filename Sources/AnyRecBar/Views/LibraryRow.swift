import AnyRecKit
import SwiftUI

struct LibraryRow: View {
    let entry: LibraryEntry
    let working: Bool
    let progress: String?
    var mark: CloudMark? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            /// The margin Notes keeps for a shared note's badge carries what a recording
            /// still needs: being worked on, or voices waiting for names.
            /// Always there, badge or not, so every row's text starts at the same edge.
            ZStack {
                Color.clear
                if working {
                    Image(systemName: "hourglass").help(progress ?? "Working…")
                } else if entry.hasUnnamedSpeech {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .help(entry.hasUnclaimedLines ? "Includes lines marked Not sure who" : Wording.unnamed(entry.unnamedVoices))
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
                Label(entry.shared.map { Wording.sharedBy($0.sharedBy) } ?? Wording.rowSource(of: entry),
                      systemImage: entry.shared != nil ? "person.2" : entry.info?.isCall == true ? "phone" : "record.circle")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            /// Synced recordings carry a cloud on the corner of their square, where it is
            /// easy to spot down the list and never cuts the text short.
            Group {
                if entry.audioOnly {
                    RowAudioMark()
                } else if entry.video != nil {
                    RowThumbnail(entry: entry)
                } else {
                    Color.clear.frame(width: 54, height: 54)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let mark { RowCloudMark(mark: mark).offset(x: 4, y: 4) }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Where the recording is, on the corner of the row's square (`TeamLibrary.mark`): its
/// synced copy up, going up or in trouble; someone else's not on this Mac yet.
private struct RowCloudMark: View {
    let mark: CloudMark

    var body: some View {
        Image(systemName: mark.symbol)
            .font(.caption)
            .foregroundStyle(mark == .failed ? Color.orange : .accentColor)
            .padding(3)
            .background(.background, in: Circle())
            .overlay(Circle().strokeBorder(.separator))
            .help(mark.label)
            .accessibilityLabel(mark.label)
    }
}

/// Where a still would be, for a recording that kept no picture: the same square, with
/// a waveform in it, so audio-only rows line up with the rest and read as sound at a glance.
private struct RowAudioMark: View {
    var body: some View {
        Image(systemName: "waveform")
            .font(.title2)
            .foregroundStyle(.secondary)
            .frame(width: 54, height: 54)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            .help(Wording.audioOnly)
            .accessibilityLabel(Wording.audioOnly)
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
        .task(id: entry.shared?.preview ?? entry.directory) {
            if entry.shared != nil { image = await SharedPreview.image(entry.shared) }
            else if let url = await Thumbnail.of(entry) { image = NSImage(contentsOf: url) }
        }
    }
}
