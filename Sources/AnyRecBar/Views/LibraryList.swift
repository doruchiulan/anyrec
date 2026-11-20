import AnyRecKit
import SwiftUI

/// Laid out the way Notes lays out its list: a large bold heading over each stretch of
/// time with a rule under it, then rows of a bold title, a date beside a line of what
/// was said, and where it came from — with a still from the video on the right.
struct LibraryList: View {
    @Bindable var controller: RecordingController
    let entries: [LibraryEntry]
    let linked: [SharedLibraryItem]

    /// A pinned section heading: `.title2` bold with its padding, as measured on screen.
    static let headingHeight: CGFloat = 40

    var body: some View {
        List(selection: $controller.selection) {
            if !linked.isEmpty { Section("Shared") { SharedMeetingRows(items: linked) } }
            ForEach(groups, id: \.name) { group in
                Section {
                    ForEach(group.entries) { entry in
                        LibraryRow(
                            entry: entry, working: controller.working.contains(entry.directory),
                            progress: controller.processingMessage(for: entry.directory),
                            publication: controller.team.publication(entry)
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
            if entries.isEmpty && linked.isEmpty {
                ContentUnavailableView(
                    "No Recordings", systemImage: "tray",
                    description: Text("Recordings appear here when they finish."))
            }
        }
        .navigationSubtitle(Wording.count(entries.count + linked.count))
    }

    /// The few things done to one recording, in the order they are reached for. Each is
    /// also in the File and Recording menus.
    @ViewBuilder private func menu(for entry: LibraryEntry) -> some View {
        Button("Show in Finder") { controller.reveal(entry) }
        if entry.media != nil {
            Button("Share Files…") { controller.share(entry) }
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

