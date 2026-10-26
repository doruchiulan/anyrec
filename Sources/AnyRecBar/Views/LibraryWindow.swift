import AnyRecKit
import SwiftUI

enum LibraryWindow {
    static let id = "library"
}

/// Every recording AnyRec has made, with what was said in it. A renderer over
/// `RecordingLibrary` and the files a recording leaves, like the panel is over the
/// session: nothing here decides what a transcript or a summary is.
///
/// Built from the system's own pieces — a sidebar, a list, a detail, an inspector, a
/// toolbar — so it behaves like every other Mac app: the sidebar collapses, the panes
/// resize, and every toolbar command is also in the menu bar.
struct LibraryView: View {
    @Bindable var controller: RecordingController
    @SceneStorage("libraryFilter") private var filter = LibraryFilter.all
    /// Open until it is closed: the transcript is half of what a recording is for.
    @SceneStorage("showsInspector") private var showsInspector = true
    /// The toolbar's measured spacing, kept across selections so it holds still, and
    /// across launches so the first layout is already right.
    @State private var strip = ToolbarStrip(remembering: Preferences.toolbarStrip)
    @State private var query = ""
    @State private var searchable: [URL: String] = [:]

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(controller: controller, filter: $filter)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            Group {
                if filter == .people {
                    PeopleList(controller: controller)
                } else {
                    LibraryList(controller: controller, entries: shown)
                }
            }
            .navigationTitle(filter.title)
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 400)
            /// The list's own button, at the end of its title row where Notes puts its list
            /// menu. A real toolbar item, so the system draws it in Liquid Glass exactly as
            /// it draws every other app's.
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button { controller.pickAndStart() } label: {
                        Label("New Recording", systemImage: "record.circle")
                    }
                    .help("Choose a window and start recording")
                    .disabled(!controller.canStart)
                }
            }
        } detail: {
            if let entry = controller.selectedEntry {
                /// Not re-identified per recording: the view reloads itself on an entry
                /// change, and tearing it down rebuilt the toolbar, which jumped.
                RecordingDetail(
                    controller: controller, entry: entry, showsInspector: $showsInspector,
                    strip: $strip)
            } else {
                ContentUnavailableView(
                    "No Recording Selected", systemImage: "waveform",
                    description: Text("Choose a recording, or start a new one."))
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search Transcripts")
        .sheet(item: $controller.transcriptRequest) { entry in
            TranscriptGeneration(controller: controller, entry: entry)
        }


        .task { await controller.reloadLibrary() }
        .task(id: controller.library) { await index() }
        .onChange(of: strip.memory) { _, memory in Preferences.toolbarStrip = memory }
    }

    private var shown: [LibraryEntry] {
        let filtered = controller.library.filter { filter.includes($0, working: controller.working) }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return filtered }
        return filtered.filter {
            Wording.title(of: $0).localizedCaseInsensitiveContains(needle)
                || (searchable[$0.directory]?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    /// Transcript text for search, read once per library change off the main thread.
    private func index() async {
        let entries = controller.library
        let texts = await Task.detached {
            entries.reduce(into: [URL: String]()) { texts, entry in
                if let url = entry.transcript, let transcript = Transcript.read(url) {
                    texts[entry.directory] = transcript.plainText
                }
            }
        }.value
        searchable = texts
    }
}

enum LibraryFilter: String, Hashable {
    case all, calls, transcribed, inProgress, people, unnamed

    var title: String {
        switch self {
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
        case .all, .people: true
        case .calls: entry.info?.isCall ?? false
        case .transcribed: entry.transcript != nil
        case .inProgress: working.contains(entry.directory)
        case .unnamed: entry.unnamedVoices > 0
        }
    }
}

private struct LibrarySidebar: View {
    @Bindable var controller: RecordingController
    @Binding var filter: LibraryFilter

    var body: some View {
        List(selection: Binding<LibraryFilter?>(get: { filter }, set: { filter = $0 ?? .all })) {
            Section("Library") {
                row(.all)
                row(.calls)
                row(.transcribed)
                row(.inProgress)
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
        Label(target.title, systemImage: target.symbol)
            .badge(controller.library.filter { target.includes($0, working: controller.working) }.count)
            .tag(target)
    }
}

/// The people the library can put a name to, each with a way to make it forget them.
private struct PeopleList: View {
    @Bindable var controller: RecordingController

    var body: some View {
        List(controller.people, id: \.name) { person in
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name)
                    Text(Wording.voiceprints(person.prints.count))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "person.crop.circle")
            }
            .contextMenu {
                Button("Forget \(person.name)") { controller.forget(person.name) }
            }
        }
        .overlay {
            if controller.people.isEmpty {
                ContentUnavailableView(
                    "No People", systemImage: "person.2",
                    description: Text("Name a voice in a transcript and it's recognised on the next call."))
            }
        }
        .safeAreaInset(edge: .bottom) { VoicesExchange(controller: controller) }
    }
}

/// Voices in and out as one file, so a team names each person once.
struct VoicesExchange: View {
    @Bindable var controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Import…") { controller.importVoicesPanel() }
                Button("Export…") { controller.exportVoicesPanel() }
                    .disabled(controller.people.isEmpty)
            }
            .controlSize(.small)
            if let message = controller.voicesMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.bar)
    }
}

/// Laid out the way Notes lays out its list: a large bold heading over each stretch of
/// time with a rule under it, then rows of a bold title, a date beside a line of what
/// was said, and where it came from — with a still from the video on the right.
private struct LibraryList: View {
    @Bindable var controller: RecordingController
    let entries: [LibraryEntry]

    var body: some View {
        List(selection: $controller.selection) {
            ForEach(groups, id: \.name) { group in
                Section {
                    ForEach(group.entries) { entry in
                        LibraryRow(
                            entry: entry, working: controller.working.contains(entry.directory),
                            progress: controller.processingMessage(for: entry.directory)
                        )
                        .tag(entry.directory)
                        .listRowSeparator(.visible)
                        .contextMenu { menu(for: entry) }
                    }
                } header: {
                    Text(group.name).font(.title2).bold().foregroundStyle(.primary)
                        .padding(.top, 10).padding(.bottom, 4)
                }
            }
        }
        /// Plain, not inset: under the macOS 26 SDK an inset list stops sizing its rows to
        /// their content and clips every row and heading to one line.
        .listStyle(.plain)
        .alternatingRowBackgrounds(.disabled)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Recordings", systemImage: "tray",
                    description: Text("Recordings appear here when they finish."))
            }
        }
        .navigationSubtitle(Wording.count(entries.count))
    }

    /// The few things done to one recording, in the order they are reached for. Each is
    /// also in the File and Recording menus.
    @ViewBuilder private func menu(for entry: LibraryEntry) -> some View {
        Button("Show in Finder") { controller.reveal(entry) }
        if let video = entry.video {
            ShareLink(item: video)
        }
        TranscriptAction(controller: controller, entry: entry)
        if entry.transcript != nil, controller.activeSummaryProvider != nil {
            Button(entry.summary == nil ? "Summarize" : "Summarize Again") { controller.summarize(entry) }
        }
        Divider()
        Button("Move to Trash") { controller.trash(entry) }
            .disabled(controller.working.contains(entry.directory))
    }

    private var groups: [(name: String, entries: [LibraryEntry])] {
        var groups: [(name: String, entries: [LibraryEntry])] = []
        for entry in entries {
            let name = Wording.group(entry.started)
            if let last = groups.indices.last, groups[last].name == name {
                groups[last].entries.append(entry)
            } else {
                groups.append((name, [entry]))
            }
        }
        return groups
    }
}
