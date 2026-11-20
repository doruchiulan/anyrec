import AnyRecKit
import AVKit
import SwiftUI

struct SharedMeetingRows: View {
    let items: [SharedLibraryItem]
    var body: some View {
        ForEach(items) { item in
            VStack(alignment: .leading, spacing: 4) {
                Text(item.meeting.title).font(.headline)
                Text(item.meeting.started.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tag(item.directory)
        }
    }
}

struct SharedMeetingsList: View {
    @Bindable var controller: RecordingController
    let items: [SharedLibraryItem]

    var body: some View {
        List(selection: $controller.selection) { SharedMeetingRows(items: items) }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("No shared meetings", systemImage: "folder.badge.person.crop")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading) {
                    ForEach(controller.team.snapshot?.state.folders ?? [], id: \.self) { folder in
                        Label(folder.lastPathComponent, systemImage: "folder")
                            .help(folder.path)
                        if let issue = controller.team.snapshot?.failures[folder] { Text(issue).font(.caption) }
                    }
                    Button("Connect team folder…") { controller.team.connect() }.disabled(controller.team.busy)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
    }
}

struct SharedMeetingDetail: View {
    let item: SharedLibraryItem
    @Bindable var controller: RecordingController
    @State private var player: AVPlayer?
    @State private var mediaError: String?
    @State private var attempt = 0
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.meeting.title).font(.title2.bold())
            if let player { VideoPlayer(player: player).frame(minHeight: 100, maxHeight: 260) }
            else if let mediaError {
                HStack {
                    Text(mediaError)
                    Button("Retry") { attempt += 1 }
                }
            } else { ProgressView("Opening recording…") }
            if let notes = item.meeting.notes {
                DisclosureGroup("Summary") {
                    ScrollView { Text(notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 180)
                }
            }
            TextField("Find in transcript", text: $query).textFieldStyle(.roundedBorder)
            List {
                ForEach(Array((item.meeting.transcript?.utterances ?? []).enumerated()), id: \.offset) { _, line in
                    if query.isEmpty || (line.speaker.label + " " + line.text).localizedStandardContains(query) {
                        Button {
                            player?.seek(to: CMTime(seconds: line.start, preferredTimescale: 600))
                            player?.play()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(Wording.clock(line.start) + "  " + line.speaker.label).font(.caption.bold())
                                Text(line.text)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding()
        .toolbar {
            SlackDraftButton(title: item.meeting.title, summary: item.meeting.notes, audioOnly: item.meeting.audioOnly)
            if controller.team.snapshot?.state.linked.contains(item.directory) == false {
                Button("Add to Library") { controller.team.add(item) }.disabled(controller.team.busy)
            }
            Button("Make a Copy") { controller.team.copy(item, controller: controller) }.disabled(controller.team.busy)
        }
        .task(id: attempt) {
            player?.pause()
            player = nil
            mediaError = nil
            do {
                let url = try await item.meeting.playableFile(in: item.directory)
                try Task.checkCancellation()
                player = AVPlayer(url: url)
            } catch {
                if !Task.isCancelled { mediaError = error.localizedDescription }
            }
        }
        .onDisappear { player?.pause() }
    }
}
