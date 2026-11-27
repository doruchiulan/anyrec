import AnyRecKit
import SwiftUI

/// Under the player's controls: what pressing play will fetch, how far it has got, and what
/// is in the way. Gone once the recording is here and nothing else is being fetched.
struct SharedDownloadStatus: View {
    let shared: SharedOrigin
    let playback: Playback
    let download: SharedDownload

    private var cloud: String { CloudFolder.provider(of: shared.media) ?? "the team folder" }

    var body: some View {
        Group {
            switch download.state {
            case .idle:
                if !playback.isReady {
                    Label(Wording.downloadsOnPlay(bytes: shared.mediaBytes, cloud: cloud), systemImage: "icloud.and.arrow.down")
                }
            case .downloading(let done, let total, let stalled):
                HStack(spacing: 8) {
                    if done > 0, total > 0 {
                        ProgressView(value: Double(min(done, total)), total: Double(total)).frame(maxWidth: 160)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(stalled ? Wording.downloadStalled(cloud: cloud) : Wording.downloading(done: done, total: total, cloud: cloud))
                        .monospacedDigit()
                    cancel
                }
            case .waitingForOwner:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Wording.waitingForOwner(shared.sharedBy))
                    cancel
                }
            case .failed(let reason):
                HStack(spacing: 8) {
                    Label(reason, systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
                    Button("Try Again") { download.retry() }.controlSize(.small)
                }
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var cancel: some View {
        Button { download.cancel() } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).help("Stop waiting").accessibilityLabel("Stop waiting for the download")
    }
}

/// The still from the recording, where its picture will be, until it is here.
struct SharedStill: View {
    let entry: LibraryEntry
    let playback: Playback
    @State private var image: NSImage?

    var body: some View {
        Group {
            if entry.shared != nil, !playback.isReady, let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .task(id: entry.shared?.preview) { image = await SharedPreview.image(entry.shared) }
    }
}

enum SharedPreview {
    /// The published still, fetched first when it is only in the cloud: it is small.
    static func image(_ shared: SharedOrigin?) async -> NSImage? {
        guard let file = shared?.preview else { return nil }
        guard let data = await smallFile(file) else { return nil }
        return NSImage(data: data)
    }

    /// A small published file's contents, once it is here. Nil when it has not arrived
    /// within a minute, or cannot be had.
    static func smallFile(_ file: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            for attempt in 0..<120 {
                switch CloudFile.download(file) {
                case .local: return try? Data(contentsOf: file)
                case .missing: return nil
                case .remote where attempt == 0, .failed where attempt == 0: try? CloudFile.requestDownload(file)
                case .failed: return nil
                case .remote, .downloading: break
                }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return nil }
            }
            return nil
        }.value
    }
}

/// Beside a shared file that is not on this Mac: only in the cloud, or not uploaded yet.
struct SharedFileMark: View {
    let file: URL
    @State private var state: CloudFile.Download?

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 0, height: 0)
            switch state {
            case .remote, .failed: Image(systemName: "icloud.and.arrow.down").help("In the cloud")
            case .downloading: Image(systemName: "arrow.down.circle").help("Downloading")
            case .missing: Image(systemName: "clock").help("Not uploaded yet")
            case .local, nil: EmptyView()
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .task(id: file) {
            while !Task.isCancelled {
                let found = await Task.detached(priority: .utility) { [file] in CloudFile.download(file) }.value
                if state != found { state = found }
                guard found != .local else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

/// How a shared transcript was reviewed, and what each engine wrote: the same strip as the
/// owner's, from the files the meeting carries.
struct SharedReviewDetails: View {
    let directory: URL
    let meeting: SharedMeeting
    @State private var sources: [SharedSource] = []
    @State private var shows = false
    @State private var fetching = false

    var body: some View {
        if meeting.reviewedBy != nil || (meeting.sourceCount ?? 0) > 1 || meeting.reviewFailures?.isEmpty == false {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Wording.reviewTitle(provider: meeting.reviewedBy, failed: meeting.reviewFailures?.isEmpty == false))
                            .font(.callout.bold())
                        if let count = meeting.sourceCount { Text(Wording.versions(count)).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if meeting.sourceCount != nil {
                        if fetching { ProgressView().controlSize(.small) }
                        Button("View Sources…") { Task { await open() } }.disabled(fetching)
                    }
                }
                ForEach(meeting.reviewFailures ?? [], id: \.self) { Notice($0, level: .advisory) }
            }
            .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .sheet(isPresented: $shows) {
                TranscriptSourcesView(sources: sources.map { .init(title: Wording.version($0), text: $0.transcript.plainText) },
                                      failures: meeting.reviewFailures ?? [])
            }
        }
    }

    private func open() async {
        fetching = true
        defer { fetching = false }
        _ = await SharedPreview.smallFile(SharedMeeting.sourcesFile(in: directory))
        sources = await Task.detached { [directory] in SharedMeeting.sources(in: directory) }.value
        shows = !sources.isEmpty
    }
}
