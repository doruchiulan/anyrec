import AnyRecKit
import SwiftUI

struct LibraryRow: View {
    let entry: LibraryEntry
    let working: Bool
    let progress: String?
    /// Where the recording was synced for the team, if it was; one of the places the cloud
    /// mark looks.
    var publication: MeetingPublication? = nil

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
            .overlay(alignment: .bottomTrailing) { RowCloudMark(entry: entry, publication: publication).offset(x: 4, y: 4) }
        }
        .padding(.vertical, 6)
    }
}

/// A cloud badge on the row's square when the recording is uploaded somewhere: the team's
/// sync folder, a shared link, or a OneDrive or iCloud copy. The same check as the
/// recording page's (`RecordingCloud.isAvailable`), read off the main thread while the row
/// is on screen, again every 30 s while the app is in front: it reads cloud status from
/// disk, and a list holds many rows.
private struct RowCloudMark: View {
    let entry: LibraryEntry
    let publication: MeetingPublication?
    @Environment(\.scenePhase) private var phase
    @State private var uploaded = false

    private struct Poll: Equatable {
        let phase: ScenePhase
        let directory: URL
        let folder: URL?
        let revision: Date?
    }

    var body: some View {
        /// A zero-size view that is always there: on an empty `Group` (nothing to show
        /// yet) SwiftUI never started the task, so no row ever found out it was synced.
        HStack(spacing: 0) {
            Color.clear.frame(width: 0, height: 0)
            if uploaded {
                Image(systemName: "icloud.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(3)
                    .background(.background, in: Circle())
                    .overlay(Circle().strokeBorder(.separator))
                    .help("Recording available in the cloud")
                    .accessibilityLabel("Recording available in the cloud")
            }
        }
        .task(id: Poll(phase: phase, directory: entry.directory, folder: publication?.directory, revision: entry.revision)) {
            repeat {
                let available = await Task.detached(priority: .utility) { [entry, publication] in
                    RecordingCloud.isAvailable(for: entry, publication: publication)
                }.value
                guard !Task.isCancelled else { return }
                if uploaded != available { uploaded = available }
                guard phase == .active else { return }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
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
        .task(id: entry.directory) {
            if let url = await Thumbnail.of(entry) { image = NSImage(contentsOf: url) }
        }
    }
}
