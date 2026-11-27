import AnyRecKit
import SwiftUI

enum LibraryFilter: String, Hashable {
    /// This Mac's recordings and the meetings colleagues synced to the sync location.
    case all, mine, shared, people, unnamed

    var title: String {
        switch self {
        case .all: "All Recordings"
        case .mine: "Mine"
        case .shared: "Shared with You"
        case .people: "People"
        case .unnamed: "Unnamed Voices"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .mine: "person"
        case .shared: "shared.with.you"
        case .people: "person.2"
        case .unnamed: "person.crop.circle.badge.questionmark"
        }
    }

    /// Whether one of this Mac's own recordings is listed.
    func includes(_ entry: LibraryEntry) -> Bool {
        switch self {
        case .all, .mine, .people: true
        case .shared: false
        case .unnamed: entry.hasUnnamedSpeech
        }
    }

    /// Whether a colleague's meeting is listed. Nobody can name the voices in one.
    var includesShared: Bool { self == .all || self == .shared }
}

struct LibrarySidebar: View {
    @Bindable var controller: RecordingController
    @Binding var filter: LibraryFilter

    var body: some View {
        List(selection: Binding<LibraryFilter?>(get: { filter }, set: { filter = $0 ?? .all })) {
            Section("Library") {
                row(.all)
                row(.mine)
                row(.shared)
            }
            Section("Speakers") {
                Label(LibraryFilter.people.title, systemImage: LibraryFilter.people.symbol)
                    .badge(controller.people.count)
                    .tag(LibraryFilter.people)
                row(.unnamed)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ target: LibraryFilter) -> some View {
        let own = controller.library.filter(target.includes).count
        let shared = target.includesShared ? controller.team.entries.count : 0
        return Label(target.title, systemImage: target.symbol)
            .badge(own + shared)
            .tag(target)
    }
}
