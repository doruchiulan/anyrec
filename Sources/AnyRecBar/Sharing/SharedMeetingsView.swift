import AnyRecKit
import SwiftUI

/// Every meeting in the connected team folders, listed as the library lists its own, with
/// the folders themselves under them.
struct SharedMeetingsList: View {
    @Bindable var controller: RecordingController
    let entries: [LibraryEntry]

    private var team: TeamLibrary { controller.team }

    var body: some View {
        let folders = team.snapshot?.state.folders ?? []
        LibraryList(
            controller: controller, entries: entries,
            empty: folders.isEmpty
                ? ("No Shared Meetings", "folder.badge.person.crop", "Connect the team folder your colleagues sync to.")
                : ("No Shared Meetings", "folder.badge.person.crop", "Meetings appear here when a colleague syncs one."))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if let arriving = team.snapshot?.arriving, arriving > 0 {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(Wording.arriving(arriving)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(folders, id: \.self) { folder in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(Wording.syncFolder(folder), systemImage: "folder").lineLimit(1).truncationMode(.middle)
                        if let issue = team.snapshot?.failures[folder] { Text(issue).font(.caption).foregroundStyle(.orange) }
                    }
                    .help(folder.path)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        Button("Disconnect") { team.disconnect(folder) }
                    }
                }
                let unreadable = unreadable(folders)
                if unreadable > 0 {
                    Text(unreadable == 1 ? "1 meeting couldn't be read" : "\(unreadable) meetings couldn't be read")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("Connect Team Folder…") { team.connect() }.disabled(team.busy)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func unreadable(_ folders: [URL]) -> Int {
        (team.snapshot?.failures.keys ?? [:].keys).filter { folders.contains($0.deletingLastPathComponent()) }.count
    }
}
