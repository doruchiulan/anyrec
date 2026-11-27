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
    @State private var query = ""
    @State private var searchable: [URL: String] = [:]
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var compact = CompactColumns()
    @State private var window: NSWindow?
    /// The recording the detail shows, shared with the inspector beside it.
    @State private var opened: OpenRecording?

    var body: some View {
        NavigationSplitView(columnVisibility: columnsShown) {
            LibrarySidebar(controller: controller, filter: $filter)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            Group {
                if filter == .people {
                    PeopleList(controller: controller)
                } else if filter == .shared {
                    SharedMeetingsList(controller: controller, entries: shared)
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
            if let entry = shownEntry {
                /// Not re-identified per recording: the view reloads itself on an entry
                /// change, and tearing it down rebuilt the toolbar, which jumped.
                RecordingDetail(
                    controller: controller, entry: entry, recording: opened, showsInspector: inspectorShown)
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
        /// Before the inspector: applied around it, the field was placed twice — in the
        /// sidebar and again at the window's trailing edge.
        .searchable(text: $query, placement: .sidebar, prompt: "Search Transcripts")
        /// On the split view, not the page: only there is the inspector a full-height column
        /// with its own section of the toolbar. Inside the detail it sat under one toolbar
        /// strip shared with the page, which no item can say ends at the page's edge.
        .inspector(isPresented: inspectorPresented) {
            if let entry = shownEntry, let opened, opened.directory == entry.directory {
                RecordingInspector(
                    controller: controller, entry: entry, recording: opened, showsInspector: inspectorShown)
            } else {
                Color.clear.inspectorColumnWidth(min: 300, ideal: 400, max: 600)
            }
        }
        .task(id: shownEntry?.media ?? shownEntry?.directory) {
            opened?.playback.stop()
            guard let entry = shownEntry else {
                opened = nil
                return
            }
            let open = OpenRecording(entry, controller: controller)
            open.load(entry)
            opened = open
            await open.playback.loadWaveform(shared: open.sharedWaveform)
        }
        .onDisappear { opened?.playback.stop() }
        .alert("Meeting sync", isPresented: Binding(get: { controller.team.error != nil }, set: { if !$0 { controller.team.error = nil } })) {
            Button("OK") { controller.team.error = nil }
        } message: { Text(controller.team.error ?? "") }
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
        .onChange(of: controller.selection) { _, _ in
            if filter == .shared, controller.selectedEntry != nil { filter = .all }
        }
        .background(LibraryWindowReader { found in if window !== found { window = found } })
        .task { await controller.reloadLibrary() }
        .task(id: controller.library) { await index() }
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

    /// Shown only beside a recording: an empty selection has nothing to put in it.
    private var inspectorPresented: Binding<Bool> {
        Binding(get: { showsInspector && shownEntry != nil }, set: { shown in
            if shownEntry != nil { inspectorShown.wrappedValue = shown }
        })
    }

    /// The recording the detail shows, when it shows one: this Mac's own, or someone else's
    /// from a team folder.
    private var shownEntry: LibraryEntry? {
        if let shared = (filter == .shared ? shared : linked).first(where: { $0.directory == controller.selection }) { return shared }
        return filter == .shared ? nil : controller.selectedEntry
    }

    private var sidebarHidden: Bool { columns == .doubleColumn || columns == .detailOnly }

    private var shared: [LibraryEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return controller.team.entries }
        return controller.team.entries.filter { entry in
            Wording.title(of: entry).localizedCaseInsensitiveContains(needle)
                || controller.team.meeting(entry.directory)?.transcript?.plainText.localizedCaseInsensitiveContains(needle) == true
        }
    }

    /// Shared meetings added to the library, listed among this Mac's own.
    private var linked: [LibraryEntry] {
        shared.filter { controller.team.isLinked($0.directory) && filter.includes($0) }
    }

    private var shown: [LibraryEntry] {
        let filtered = controller.library.filter { filter.includes($0, working: controller.working) }
        let needle = query.trimmingCharacters(in: .whitespaces)
        let own = needle.isEmpty ? filtered : filtered.filter {
            Wording.title(of: $0).localizedCaseInsensitiveContains(needle)
                || (searchable[$0.directory]?.localizedCaseInsensitiveContains(needle) ?? false)
        }
        let linked = linked
        return linked.isEmpty ? own : (own + linked).sorted { $0.started > $1.started }
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
