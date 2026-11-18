import AppKit
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
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var compact = CompactColumns()
    @State private var window: NSWindow?

    var body: some View {
        NavigationSplitView(columnVisibility: columnsShown) {
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
            /// With the sidebar hidden, this column's toolbar row also holds the window
            /// buttons and the sidebar toggle; at 240 pt the title ran under the record
            /// button. Fixed rather than switched with the sidebar: a minimum that changed
            /// while the sidebar collapsed sent the split view into a layout loop that hung
            /// the app.
            .navigationSplitViewColumnWidth(min: CompactColumns.list, ideal: CompactColumns.list, max: 400)
        } detail: {
            if let entry = controller.selectedEntry {
                /// Not re-identified per recording: the view reloads itself on an entry
                /// change, and tearing it down rebuilt the toolbar, which jumped.
                RecordingDetail(
                    controller: controller, entry: entry, showsInspector: inspectorShown,
                    strip: $strip)
            } else {
                ContentUnavailableView {
                    Label("No Recording Selected", systemImage: "waveform")
                } description: {
                    Text("Choose a recording, or start a new one.")
                } actions: {
                    NewRecordingButton(controller: controller) { Text(Wording.newRecording(video: true)) }
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search Transcripts")
        .sheet(item: $controller.transcriptRequest) { entry in
            TranscriptGeneration(controller: controller, entry: entry)
        }


        /// A narrow window gives up the sidebar, then the inspector (`CompactColumns`).
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            let change = compact.resized(
                to: width, sidebarVisible: !sidebarHidden,
                inspectorVisible: showsInspector)
            if let sidebar = change.sidebar { withAnimation { columns = sidebar ? .all : .doubleColumn } }
            if let inspector = change.inspector { withAnimation { showsInspector = inspector } }
        }
        .onChange(of: columns) { _, columns in
            if columns == .all { compact.sidebarShown() }
        }
        .onChange(of: showsInspector) { _, shown in
            if shown { compact.inspectorShown() }
        }
        .background(LibraryWindowReader { found in if window !== found { window = found } })
        .task { await controller.reloadLibrary() }
        .task(id: controller.library) { await index() }
        .onChange(of: strip.memory) { _, memory in Preferences.toolbarStrip = memory }
    }

    /// Room for a column just shown, by hand or brought back here: nothing changes when the
    /// window is already wide enough.
    /// What the sidebar toggle and the inspector's ⓘ (and their menu commands) write
    /// through. Shown in a window too narrow for it, the column used to slide in while the
    /// window grew around it: two animations at once, with the list and the recording
    /// squeezed under their minimums in between. Now the window grows first, at once, and
    /// the column is shown on the next turn into room that is already there.
    private var columnsShown: Binding<NavigationSplitViewVisibility> {
        Binding(get: { columns }, set: { visibility in
            guard visibility == .all, sidebarHidden, grow(to: CompactColumns.sidebar.show) else {
                columns = visibility
                return
            }
            DispatchQueue.main.async { columns = visibility }
        })
    }

    private var inspectorShown: Binding<Bool> {
        Binding(get: { showsInspector }, set: { shown in
            guard shown, !showsInspector, grow(to: CompactColumns.inspector.show) else {
                showsInspector = shown
                return
            }
            DispatchQueue.main.async { showsInspector = true }
        })
    }

    /// Widens the window to `width` without animating, so a column can then be shown into
    /// the room. False when it was already wide enough, or there is no window yet.
    private func grow(to width: CGFloat) -> Bool {
        guard let window, let screen = window.screen?.visibleFrame,
              let frame = CompactColumns.grown(window.frame, to: width, within: screen) else { return false }
        window.setFrame(frame, display: true, animate: false)
        return true
    }

    private var sidebarHidden: Bool { columns == .doubleColumn || columns == .detailOnly }

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
                if entry.transcript != nil, let current = RecordingTranscript.read(in: entry.directory) {
                    texts[entry.directory] = current.named.plainText
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
                    Text(Wording.person(person))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: person.isOwner ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
            }
            .contextMenu {
                if person.isOwner {
                    Button("This Isn’t Me") { controller.setOwner(nil) }
                } else {
                    Button("This Is Me") { controller.setOwner(person.name) }
                }
                if !person.prints.isEmpty {
                    Menu("Remove Voiceprint") {
                        ForEach(Array(person.prints.indices), id: \.self) { index in
                            let origin = person.origin(ofPrint: index)
                            Button(Wording.printOrigin(origin, number: index + 1,
                                                       title: controller.recordingTitle(folder: origin?.recording))) {
                                controller.removePrint(at: index, from: person.name)
                            }
                        }
                    }
                }
                Divider()
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

    /// A pinned section heading: `.title2` bold with its padding, as measured on screen.
    static let headingHeight: CGFloat = 40

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
        /// The scroller starts under the pinned heading ("Today"), not above it.
        .contentMargins(.top, Self.headingHeight, for: .scrollIndicators)
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
        if entry.media != nil {
            Button("Share…") { controller.share(entry) }
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

/// Hands over the library's `NSWindow`, which `LibraryView` grows when a column needs room.
private struct LibraryWindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.found = found
        return view
    }

    func updateNSView(_ view: Reader, context: Context) { view.found = found }

    final class Reader: NSView {
        var found: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { [weak self] in self?.found?(window) }
        }
    }
}
