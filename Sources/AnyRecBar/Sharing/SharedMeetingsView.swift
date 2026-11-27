import AnyRecKit
import SwiftUI

/// Shared with You: the meetings colleagues synced to the sync location, listed as the
/// library lists its own. A filter, nothing more: the location is chosen from a recording's
/// Sync button, or in Settings › Recording › Sharing.
struct SharedMeetingsList: View {
    @Bindable var controller: RecordingController
    let entries: [LibraryEntry]

    private var team: TeamLibrary { controller.team }

    var body: some View {
        LibraryList(
            controller: controller, entries: entries,
            empty: team.location == nil
                ? ("Nothing Shared Yet", "shared.with.you", Wording.noSyncLocation)
                : ("Nothing Shared Yet", "shared.with.you", "Meetings appear here when a colleague syncs one to \(Wording.syncFolder(team.location!))."))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let note {
                HStack(spacing: 6) {
                    if team.snapshot?.arriving ?? 0 > 0 { ProgressView().controlSize(.small) }
                    Text(note).font(.caption).foregroundStyle(team.snapshot?.arriving ?? 0 > 0 ? .secondary : Color.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    /// Meetings still on their way, else what could not be read.
    private var note: String? {
        if let arriving = team.snapshot?.arriving, arriving > 0 { return Wording.arriving(arriving) }
        guard let location = team.location else { return nil }
        if let issue = team.snapshot?.failures[location] { return issue }
        let unreadable = (team.snapshot?.failures.keys ?? [:].keys).filter { $0.deletingLastPathComponent() == location }.count
        return unreadable == 0 ? nil : unreadable == 1 ? "1 meeting couldn't be read" : "\(unreadable) meetings couldn't be read"
    }
}
