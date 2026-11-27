import AnyRecKit
import SwiftUI

enum LibraryFilter: String, Hashable {
    case all, calls, transcribed, inProgress, people, unnamed, shared

    var title: String {
        switch self {
        case .shared: "Shared with me"
        case .all: "All Recordings"
        case .calls: "Calls"
        case .transcribed: "Transcribed"
        case .inProgress: "In Progress"
        case .people: "People"
        case .unnamed: "Unnamed Voices"
        }
    }

    var symbol: String {
        switch self {
        case .shared: "folder.badge.person.crop"
        case .all: "tray.full"
        case .calls: "phone"
        case .transcribed: "text.bubble"
        case .inProgress: "hourglass"
        case .people: "person.2"
        case .unnamed: "person.crop.circle.badge.questionmark"
        }
    }

    func includes(_ entry: LibraryEntry, working: Set<URL> = []) -> Bool {
        switch self {
        case .shared: false
        case .all, .people: true
        case .calls: entry.info?.isCall ?? false
        case .transcribed: entry.transcript != nil
        case .inProgress: working.contains(entry.directory)
        case .unnamed: entry.hasUnnamedSpeech
        }
    }
}

struct LibrarySidebar: View {
    @Bindable var controller: RecordingController
    @Binding var filter: LibraryFilter

    var body: some View {
        List(selection: Binding<LibraryFilter?>(get: { filter }, set: { filter = $0 ?? .all })) {
            Section("Library") {
                row(.all)
                row(.calls)
                row(.transcribed)
                row(.inProgress)
                Label(LibraryFilter.shared.title, systemImage: LibraryFilter.shared.symbol)
                    .badge(controller.team.snapshot?.meetings.count ?? 0).tag(LibraryFilter.shared)
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
        let linked = controller.team.entries.filter { controller.team.isLinked($0.directory) && target.includes($0) }
        return Label(target.title, systemImage: target.symbol)
            .badge(controller.library.filter { target.includes($0, working: controller.working) }.count + linked.count)
            .tag(target)
    }
}

