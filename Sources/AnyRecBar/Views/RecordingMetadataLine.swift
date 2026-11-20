import AnyRecKit
import SwiftUI

struct RecordingMetadataLine: View {
    let entry: LibraryEntry
    let publication: MeetingPublication?
    @Environment(\.scenePhase) private var phase
    @State private var uploaded = false

    private struct Poll: Equatable {
        let phase: ScenePhase
        let entry: URL
        let folder: URL?
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(Wording.meta(of: entry))
            if uploaded {
                /// The list's badge, so a synced recording looks synced everywhere.
                Image(systemName: "icloud.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Recording available in the cloud")
                    .help("Recording available in the cloud")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .task(id: Poll(phase: phase, entry: entry.directory, folder: publication?.directory)) {
            repeat {
                let available = await Task.detached(priority: .utility) { [entry] in
                    RecordingCloud.isAvailable(for: entry, publication: publication)
                }.value
                guard !Task.isCancelled else { return }
                uploaded = available
                guard phase == .active else { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled
        }
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

    /// Whether the synced copy is up in the cloud. The cloud badge means exactly this: a
    /// saved link, an old export or a recording folder kept in a cloud drive no longer count,
    /// because "in the cloud" read as "synced" and they were not.
    static func isAvailable(for entry: LibraryEntry, publication: MeetingPublication? = nil) -> Bool {
        syncedMedia(for: entry, publication: publication).map(isUploaded) ?? false
    }

    private static func isUploaded(_ file: URL) -> Bool {
        let values = try? file.resourceValues(forKeys: [
            .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey
        ])
        return values?.ubiquitousItemIsUploaded == true && values?.ubiquitousItemIsUploading != true
            && values?.ubiquitousItemUploadingError == nil
    }
}
