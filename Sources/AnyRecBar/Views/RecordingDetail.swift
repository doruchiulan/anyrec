import AVKit
import AnyRecKit
import SwiftUI

/// One recording opened in the library window: its player, and what was read from its
/// folder. Owned by the window rather than the page, because the page and the inspector
/// beside it both read it — and the inspector is attached to the window's split view, not
/// to the page, so that it is a column of its own with its own section of the toolbar.
///
/// Made when a recording is opened, never in a view's `init`: a view's `init` runs on every
/// redraw of its parent, and a player made there was a new `AVPlayer`, a new time observer
/// and a fresh decode of the whole call's audio each time the list filtered or the library
/// reloaded.
@MainActor
@Observable
final class OpenRecording {
    let playback: Playback
    private let controller: RecordingController
    private(set) var transcript: Transcript?
    private(set) var voices: RecordingVoices?
    private(set) var observed: CallParticipants?
    private var observedRead = false
    private(set) var desk: SpeakerDesk?
    private(set) var summary: RecordingSummaryPresentation?
    private(set) var legacySummary: String?
    /// The transcript with names in, worked out when it loads rather than on each redraw.
    private(set) var lines: [Utterance] = []
    /// The inspector's transcript shows only this speaker's lines when set. The People panel
    /// sets it to the lines nobody claimed, which are answered there one by one: 175 of them
    /// laid out in the panel at once slowed the whole page.
    var transcriptFilter: Speaker?

    init(_ entry: LibraryEntry, controller: RecordingController) {
        playback = Playback(entry)
        self.controller = controller
    }

    var directory: URL { playback.entry.directory }

    /// The waveform someone else's recording was published with.
    private(set) var sharedWaveform: [Float]?
    /// Someone else's recording as it was last read, so an unchanged one is not laid out again.
    private(set) var shared: SharedMeeting?

    /// Someone else's recording, all of it from its manifest: nothing here waits for a file.
    private func load(shared meeting: SharedMeeting, in directory: URL) {
        guard shared != meeting else { return }
        shared = meeting
        transcript = meeting.transcript
        voices = nil
        named()
        desk = SpeakerDesk(shared: meeting.speakers(), directory: directory, controller: controller)
        summary = nil
        legacySummary = meeting.legacySummary
        setSummary(meeting.summary)
        sharedWaveform = meeting.waveform
    }

    func load(_ entry: LibraryEntry) {
        if entry.shared != nil {
            if let meeting = controller.team.meeting(entry.directory) { load(shared: meeting, in: entry.directory) }
            return
        }
        let current = RecordingTranscript.read(in: entry.directory)
        transcript = current?.transcript
        voices = current?.voices
        /// The call window's polls do not change once the call is over, and a long call's take
        /// half a second to decode: read once, not on every answer that moves the entry.
        if !observedRead {
            observed = CallParticipants.read(in: entry.directory)
            observedRead = true
        }
        named()
        if desk?.directory != entry.directory {
            desk = SpeakerDesk(directory: entry.directory, controller: controller)
            desk?.participants = .some(observed)
        }
        if let desk { Task { await desk.load() } }
        summary = nil
        legacySummary = nil
        if let url = entry.summary {
            if url.pathExtension == "json" {
                setSummary(Summary.read(url))
            } else {
                legacySummary = try? String(contentsOf: url, encoding: .utf8)
            }
        }
    }

    func setSummary(_ original: Summary?) {
        summary = original.map { RecordingSummaryPresentation($0, transcript: transcript, names: voices?.names ?? [:]) }
    }

    /// Voices carry their names; Me stays Me so it keeps its colour and its choices, and only
    /// its label shows the owner's name (`meName`).
    private func named() {
        lines = transcript?.named((voices?.names ?? [:]).filter { $0.key != RecordingVoices.meKey }).utterances ?? []
        playback.follow(transcript)
    }
}

/// One recording's page, once its `OpenRecording` is the one selected.
struct RecordingDetail: View {
    @Bindable var controller: RecordingController
    let entry: LibraryEntry
    let recording: OpenRecording?
    @Binding var showsInspector: Bool

    var body: some View {
        if let recording, recording.directory == entry.directory {
            RecordingPage(controller: controller, entry: entry, recording: recording, showsInspector: $showsInspector)
                .focusedSceneValue(\.playback, recording.playback)
        } else {
            Color.clear
        }
    }
}

/// Opens and closes the inspector. Over the recording while the inspector is closed, and
/// at the end of the inspector's own toolbar while it is open, so it stays at the window's
/// trailing edge either way.
private struct InspectorToggle: View {
    @Binding var shown: Bool

    var body: some View {
        Button { shown.toggle() } label: {
            Label(shown ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
        }
        .help(shown ? "Hide the transcript, tracks and files" : "Show the transcript, tracks and files")
    }
}

/// One recording: the video, its summary and who spoke, with what was said — the
/// transcript, the tracks and the files — in the inspector beside it, so the transcript
/// stays in view while the video plays. Reads the files
/// the Kit left in the folder; the only things it writes are who spoke — voice names and
/// line speakers, through `SpeakerEditing`, so the library learns the names — and ticks on
/// a summary's action items.
///
/// Nothing in this body reads the playhead. It moves ten times a second, and whatever
/// reads it is redrawn as often — so the clock, the waveform and the transcript's
/// highlight are views of their own, and this page is redrawn when it actually changes.
private struct RecordingPage: View {
    @Bindable var controller: RecordingController
    let entry: LibraryEntry
    let recording: OpenRecording
    @Binding var showsInspector: Bool

    @State private var editCopy = false
    @State private var popout: NSWindow?

    private var playback: Playback { recording.playback }
    private var transcript: Transcript? { recording.transcript }
    private var voices: RecordingVoices? { recording.voices }
    private var observed: CallParticipants? { recording.observed }
    private var isShared: Bool { entry.shared != nil }
    private var desk: SpeakerDesk? { recording.desk }
    private var summary: RecordingSummaryPresentation? { recording.summary }
    private var legacySummary: String? { recording.legacySummary }
    private var lines: [Utterance] { recording.lines }

    var body: some View {
        ResizeViewport {
            document
        }
        /// White, like a document; the cards sit on it in a soft grey. Both are system
        /// colours, so Dark Mode turns them into near-black and a lifted grey.
        .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea())
        /// Floats over the page's top-right corner, in the row the window's controls use,
        /// rather than holding a toolbar row of its own.
        .toolbar { actions }
        .sheet(isPresented: $editCopy) {
            if let transcript = RecordingTranscript.read(in: entry.directory)?.named {
                CopyTranscriptEditor(directory: entry.directory, transcript: transcript) {
                    recording.load(entry)
                    Task { await controller.reloadLibrary() }
                }
            }
        }
        .onChange(of: entry) { recording.load(entry) }
    }

    private var document: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ProcessingStatusView(controller: controller, directory: entry.directory)
                    if entry.media != nil || !playback.available.isEmpty { playerCard }
                    if let shared = recording.shared {
                        SharedReviewDetails(directory: entry.directory, meeting: shared)
                    } else {
                        TranscriptReviewDetails(directory: entry.directory).id(entry.revision)
                    }
                    if transcript != nil && (!isShared || summary != nil || legacySummary != nil) { summaryCard.disabled(controller.processing.working.contains(entry.directory)) }
                    speakersSection.id(Self.speakersAnchor)
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: controller.speakersRequest, initial: true) { _, request in
                guard let request, request == entry.directory else { return }
                controller.speakersRequest = nil
                withAnimation { reader.scrollTo(Self.speakersAnchor, anchor: .top) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Wording.title(of: entry)).font(.system(size: 18, weight: .semibold))
                RecordingMetadataLine(entry: entry, mark: controller.team.mark(entry), note: controller.team.note(entry))
                /// Why nothing here can be changed, and the way to a copy that can be.
                if let shared = entry.shared {
                    HStack(spacing: 4) {
                        Label(Wording.sharedBy(shared.sharedBy), systemImage: "person.crop.circle")
                        Text("·")
                        Text("View only").help("Only the person who recorded it can change it. Make a Copy to edit your own.")
                        if controller.team.copying.contains(entry.directory) {
                            Text("·")
                            ProgressView().controlSize(.mini)
                            Text("Making a copy…")
                        }
                        if !controller.team.isLinked(entry.directory) {
                            Text("·")
                            Button("Add to Library") { controller.team.add(entry.directory) }
                                .buttonStyle(.link).disabled(controller.team.busy)
                                .help("List this meeting with your own recordings")
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var copyButton: some View {
        let copying = controller.team.copying.contains(entry.directory)
        return Button { controller.team.copy(entry, controller: controller) } label: {
            Label("Make a Copy", systemImage: "doc.on.doc")
        }
        .labelStyle(.iconOnly)
        .help(copying ? "Copying…" : "Make your own copy, to edit its transcript and summary")
        .disabled(copying)
    }

    @ToolbarContentBuilder private var actions: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            NewRecordingButton(controller: controller) {
                Label("New Recording", systemImage: "record.circle")
            }
        }
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { controller.reveal(entry) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("Show in Finder")
            if !isShared, entry.transcript != nil && SharedCopy.exists(in: entry.directory) {
                Button("Edit transcript", systemImage: "pencil") { editCopy = true }
            }
            /// One place whoever recorded it, holding the sync button or Make a Copy, so moving
            /// between one's own recordings and shared ones rebuilds no items. A test build was
            /// twice stopped selecting a shared recording: SwiftUI re-vended the toolbar's items
            /// on a focused-values change during layout, which asked for layout again, until
            /// AppKit gave up ("more Update Constraints in Window passes than there are views").
            /// Not reproduced since, in 40 tries; what kept the focused values changing is unknown.
            ZStack {
                if isShared { copyButton } else { MeetingSyncButton(team: controller.team, entry: entry) }
            }
            SlackDraftButton(title: Wording.title(of: entry), summary: summary?.markdown ?? legacySummary,
                            audioOnly: entry.audioOnly, linkFile: isShared ? nil : RecordingCloud.linkFile(for: entry))
                .background(FileShareAnchor(controller: controller, entry: entry, request: controller.shareRequest))
        }
        /// Only while the inspector is closed; open, the inspector's own toolbar ends with it.
        if !showsInspector {
            if #available(macOS 26, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) { InspectorToggle(shown: $showsInspector) }
        }
    }

    // MARK: Player

    private var playerCard: some View {
        VStack(spacing: 12) {
            if entry.video != nil {
                Color.clear
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxHeight: 380)
                    .frame(maxWidth: .infinity)
                    .overlay { LiveResizeVideo { video } }
            } else if entry.audioOnly {
                AudioSurface(entry: entry)
            }
            WaveformBar(playback: playback).frame(height: 44)
            controls
            if let shared = entry.shared, let download = playback.download {
                SharedDownloadStatus(shared: shared, playback: playback, download: download)
            }
        }
        .padding(14)
        .card()
    }

    private var video: some View {
        ZStack(alignment: .topTrailing) {
            VideoSurface(player: playback.player)
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxHeight: 380)
                .opacity(playback.enabled.contains(.video) && playback.isReady ? 1 : 0)
                .background { SharedStill(entry: entry, playback: playback) }
                .background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity)
            if controller.showsCaptions, !lines.isEmpty, playback.isReady {
                Caption(lines: lines, meName: voices?.meName, playback: playback)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 24).padding(.bottom, 14)
                    .allowsHitTesting(false)
            }
            PlayheadClock(playback: playback)
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white)
                .padding(.horizontal, 8).frame(height: 20)
                .background(.black.opacity(0.55), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
            Button(action: openInWindow) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11))
                    .foregroundStyle(.white).frame(width: 28, height: 28)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain).padding(8)
            .disabled(!playback.isReady)
            .opacity(playback.isReady ? 1 : 0)
            .help("Open in its own window, with Picture in Picture")
            .accessibilityLabel("Open in its own window")
        }
    }

    private var aspect: CGFloat {
        guard let info = entry.info, info.height > 0 else { return 16 / 10 }
        return CGFloat(info.width) / CGFloat(info.height)
    }

    /// One row when the card is wide enough; otherwise the track buttons move to a second
    /// row. Squeezed into one, "Tracks" wrapped a letter per line and the buttons lost
    /// their names.
    ///
    /// A `Layout`, not `ViewThatFits`: that built both alternatives in the window's
    /// minimum-size pass on every frame of a resize, the largest share of the page's cost.
    private var controls: some View {
        WrappingRow(spacing: 12, rowSpacing: 10) {
            transport
            trackButtons
        }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { playback.toggle() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 13))
                    .foregroundStyle(.white).frame(width: 32, height: 32)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            PlayheadTime(playback: playback)
            Menu(Wording.rate(playback.rate)) {
                ForEach(Wording.rates, id: \.self) { rate in
                    Button(Wording.rate(rate)) { playback.rate = rate }
                }
            }
            .menuStyle(.button).controlSize(.small).fixedSize()
            if entry.video != nil, !lines.isEmpty {
                Toggle(isOn: $controller.showsCaptions) {
                    Image(systemName: controller.showsCaptions ? "captions.bubble.fill" : "captions.bubble")
                }
                .toggleStyle(.button).buttonStyle(.borderless)
                .help(controller.showsCaptions ? "Hide captions" : "Show captions")
                .accessibilityLabel("Captions")
            }
        }
        .fixedSize()
    }

    private var trackButtons: some View {
        HStack(spacing: 8) {
            if !playback.available.isEmpty { Text("Tracks").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(playback.available, id: \.self) { track in
                TrackChip(
                    title: Wording.trackName(track), on: playback.enabled.contains(track)
                ) { playback.set(track, on: !playback.enabled.contains(track)) }
            }
        }
        .fixedSize()
    }

    /// A window of its own around the same player, with the system's controls — which is
    /// where Picture in Picture and full screen live.
    private func openInWindow() {
        let view = AVPlayerView()
        view.player = playback.player
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = Wording.title(of: entry)
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        popout = window
    }

    // MARK: Summary

    private var summaryCard: some View {
        let busy = controller.summarizing.contains(entry.directory)
        let provider = controller.activeSummaryProvider
        let source = isShared ? summary.map { "\($0.original.provider) · from the transcript" }
            : provider.map { "\(summary?.original.provider ?? $0.name) · from the transcript" }
        return VStack(alignment: .leading, spacing: 12) {
            /// The source line sits beside the title when there is room and under it when
            /// there is not. Squeezed beside it, both wrapped a few letters per line.
            HeaderRow(spacing: 8, rowSpacing: 4) {
                summaryTitle
                summaryActions(busy: busy)
                if let source { summarySource(source).lineLimit(2) }
            }
            .buttonStyle(.borderless)

            if busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Summarising…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if let summary {
                structured(summary.named)
                if !isShared, let stale = summary.staleNotice {
                    HStack(alignment: .firstTextBaseline) {
                        Notice(stale, level: .advisory)
                        Button("Refresh Summary") { controller.summarize(entry) }.disabled(busy || provider == nil)
                    }
                }
            } else if let legacySummary {
                Text(legacySummary).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
            } else if let provider {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Summarise") { controller.summarize(entry) }
                            .buttonStyle(OutlineButtonStyle()).fixedSize()
                        providerMenu
                    }
                    Text("Sends the transcript text, never the audio, to \(provider.company).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("No summary provider found. Install Claude Code, Codex or Gemini CLI, or add an OpenAI key in Settings › Transcription.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let failure = controller.summaryFailures[entry.directory] { Notice(failure, level: .error) }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
        .card()
    }

    private var summaryTitle: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            Text("Summary").font(.system(size: 13, weight: .semibold))
        }
        .fixedSize()
    }

    private func summarySource(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    /// Always one view, empty before there is a summary: `HeaderRow` places its children by
    /// position, so the note must never slide into the actions' place.
    private func summaryActions(busy: Bool) -> some View {
        HStack(spacing: 8) {
            if summary != nil || legacySummary != nil {
                let text = summary?.markdown ?? legacySummary ?? ""
                Button { copy(text) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy summary").accessibilityLabel("Copy summary")
                if !isShared {
                    providerMenu
                    Button { controller.summarize(entry) } label: { Image(systemName: "arrow.clockwise") }
                        .help("Regenerate summary").accessibilityLabel("Regenerate summary")
                        .disabled(busy)
                }
            }
        }
        .fixedSize()
    }

    private var providerMenu: some View {
        Menu {
            ForEach(SummaryProvider.allCases, id: \.self) { provider in
                Button(provider.name) { controller.summaryProvider = provider }
                    .disabled(!controller.canSummarize(with: provider))
            }
        } label: {
            Text(controller.activeSummaryProvider?.name ?? "Provider").font(.system(size: 12))
        }
        .menuStyle(.button).buttonStyle(.borderless).foregroundStyle(.secondary).fixedSize()
        .accessibilityLabel("Summary provider")
    }

    private func structured(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary.overview).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
            if !summary.decisions.isEmpty {
                column("Decisions") {
                    ForEach(summary.decisions, id: \.self) { decision in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(.primary).frame(width: 4, height: 4).padding(.top, 7)
                            Text(decision).font(.system(size: 13)).textSelection(.enabled)
                        }
                    }
                }
            }
            if !summary.actions.isEmpty {
                column("Action items") {
                    ForEach(Array(summary.actions.enumerated()), id: \.offset) { index, action in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Toggle(isOn: Binding(get: { action.done }, set: { tick(index, $0) })) {
                                (Text(action.task) + Text(owner(action)).foregroundColor(.secondary))
                                    .font(.system(size: 13))
                            }
                            .toggleStyle(.checkbox)
                            .allowsHitTesting(!isShared)
                            if let at = action.at {
                                Button(Wording.clock(at)) { playback.play(from: at) }
                                    .buttonStyle(.link).monospacedDigit()
                                    .help("Play from \(Wording.clock(at))")
                            }
                        }
                    }
                }
            }
        }
    }

    private func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func owner(_ action: Summary.Action) -> String {
        action.owner.map { " — \($0)" } ?? ""
    }

    private func tick(_ index: Int, _ done: Bool) {
        guard !isShared, var original = summary?.original, let url = entry.summary, url.pathExtension == "json" else { return }
        original.actions[index].done = done
        try? original.write(to: url)
        _ = try? TranscriptStore.render(in: entry.directory)
        recording.setSummary(original)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Speakers

    private static let speakersAnchor = "speakers"

    /// Every speaker, with the roster under them; the roster alone while there is no
    /// transcript to have speakers.
    @ViewBuilder private var speakersSection: some View {
        if let desk, let speakers = desk.speakers, transcript != nil {
            PeoplePanel(desk: desk, speakers: speakers, playback: playback, app: entry.info?.appName) { speaker in
                recording.transcriptFilter = speaker
                showsInspector = true
            }
        } else if let observed, !observed.roster.isEmpty {
            GroupBox {
                ObservedParticipants(participants: observed).padding(4)
            }
        }
    }

    static func colour(_ speaker: Speaker) -> Color { SpeakerColour.of(speaker) }
}

/// What was said, the tracks and the files of the open recording, beside its page. A column
/// of the window's own — attached to the split view, not to the page — so its tabs and the
/// button that closes it sit in its own section of the toolbar, over it, rather than in one
/// strip with the page's actions.
struct RecordingInspector: View {
    @Bindable var controller: RecordingController
    let entry: LibraryEntry
    let recording: OpenRecording
    @Binding var showsInspector: Bool
    @State private var tab = Tab.transcript
    enum Tab: String, CaseIterable { case transcript = "Transcript", tracks = "Tracks", files = "Files" }

    private var playback: Playback { recording.playback }
    private var transcript: Transcript? { recording.transcript }
    private var lines: [Utterance] { recording.lines }

    var body: some View {
        ResizeViewport { content }
            .inspectorColumnWidth(min: 300, ideal: 400, max: 600)
            .onChange(of: recording.transcriptFilter) { _, filter in if filter != nil { tab = .transcript } }
            /// Only while shown: a collapsed inspector still contributes its toolbar items,
            /// which then crowded into the page's section with nothing under them.
            .toolbar {
                if showsInspector {
                    if #available(macOS 26, *) {
                        ToolbarSpacer(.flexible)
                    }
                    ToolbarItem {
                        Picker("Inspector tab", selection: $tab) {
                            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    if #available(macOS 26, *) {
                        ToolbarSpacer(.flexible)
                    }
                    ToolbarItem { InspectorToggle(shown: $showsInspector) }
                }
            }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if tab == .transcript, transcript != nil {
                HStack {
                    TranscriptFilter(lines: lines, meName: recording.voices?.meName,
                                     filter: Binding(get: { recording.transcriptFilter }, set: { recording.transcriptFilter = $0 }))
                    Spacer()
                    if entry.shared == nil { TranscriptAction(controller: controller, entry: entry) }
                }
                .padding(12)
                Divider()
            }
            Group {
                if tab == .transcript {
                    transcriptLines
                } else {
                    ScrollView {
                        Group {
                            if tab == .tracks { tracks } else { files }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder private var transcriptLines: some View {
        if transcript != nil {
            TranscriptList(lines: lines, meName: recording.voices?.meName, playback: playback, desk: entry.shared == nil ? recording.desk : nil,
                           filter: Binding(get: { recording.transcriptFilter }, set: { recording.transcriptFilter = $0 }))
        } else if entry.shared != nil {
            Text("No transcript yet").font(.headline).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TranscriptPlaceholder(controller: controller, entry: entry)
        }
    }

    /// The three masters, each with what it is, how big, and a switch for hearing it. The
    /// picture's master is `screen.mov` until a verified merge replaces it, then the merged file.
    private var tracks: some View {
        let files = Playback.files(of: entry)
        let rows: [(Playback.Track, URL)] = [
            files.video.map { (.video, $0) }, files.callAudio.map { (.callAudio, $0) }, files.microphone.map { (.microphone, $0) },
        ].compactMap { $0 }
        let shown = rows.filter { entry.shared != nil || FileManager.default.fileExists(atPath: $0.1.path) }
        return VStack(spacing: 0) {
            if shown.isEmpty { Text("This recording has no separate tracks.").font(.callout).foregroundStyle(.secondary).padding(12) }
            ForEach(shown, id: \.1) { track, url in
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Wording.trackName(track)).font(.system(size: 13))
                        Text(url.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.shared != nil { SharedFileMark(file: url) }
                    Text(Wording.size(Wording.bytes(of: url))).font(.system(size: 11)).foregroundStyle(.secondary)
                    Toggle("", isOn: Binding(
                        get: { playback.enabled.contains(track) }, set: { playback.set(track, on: $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .accessibilityLabel("Play \(Wording.trackName(track))")
                        .disabled(!playback.available.contains(track))
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless).accessibilityLabel("Show \(url.lastPathComponent) in Finder")
                }
                .padding(.horizontal, 12).frame(minHeight: 40)
                Divider()
            }
        }
    }

    private var files: some View {
        let layout = RecordingLayout(directory: entry.directory)
        let urls = (entry.shared == nil ? RecordingLayout.Place.allCases : [.top, .tracks]).flatMap { layout.files(in: $0) }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        let prefix = layout.directory.path + "/"
        func label(_ url: URL) -> String { url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent }
        return VStack(spacing: 0) {
            if entry.shared == nil { RecordingLinkButton(entry: entry, publication: controller.team.publication(entry)) }
            ForEach(urls.sorted { label($0) < label($1) }, id: \.self) { url in
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    HStack {
                        Text(label(url)).font(.system(size: 13))
                        Spacer()
                        if entry.shared != nil { SharedFileMark(file: url) }
                        Text(Wording.size(Wording.bytes(of: url))).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).frame(height: 32).contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
            }
        }
    }

}

/// The picture, without the system's transport: the page draws its own.
private struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Where the picture would be, for a recording that kept none: the recorded app's icon,
/// the window's title and that it is audio only, above the waveform and transport the
/// page already has. No black rectangle standing in for a video that does not exist.
private struct AudioSurface: View {
    let entry: LibraryEntry
    /// Looked up once per recording, not on each redraw of the page.
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Wording.title(of: entry)).font(.headline).lineLimit(2)
                Text(Wording.audioSurface(of: entry)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .task(id: entry.info?.bundleID) {
            icon = entry.info?.bundleID
                .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
    }
}

/// Loudness over time, played part in the accent colour; a click or drag seeks. Drawn
/// in one `Canvas` rather than as 120 views, because it redraws with the playhead.
private struct WaveformBar: View {
    let playback: Playback

    var body: some View {
        let peaks = playback.peaks.isEmpty ? [Float](repeating: 0.08, count: 90) : playback.peaks
        let progress = playback.duration > 0 ? playback.position / playback.duration : 0
        GeometryReader { geometry in
            Canvas { context, size in
                let gap: CGFloat = 2
                let width = max(1, (size.width - gap * CGFloat(peaks.count - 1)) / CGFloat(peaks.count))
                for (index, peak) in peaks.enumerated() {
                    let height = max(3, size.height * CGFloat(max(peak, 0.08)))
                    let bar = CGRect(
                        x: CGFloat(index) * (width + gap), y: (size.height - height) / 2,
                        width: width, height: height)
                    let played = Double(index) / Double(peaks.count) < progress
                    context.fill(
                        Path(roundedRect: bar, cornerRadius: 1),
                        with: .color(played ? .accentColor : .primary.opacity(0.2)))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged {
                    playback.seek(to: max(0, min(1, $0.location.x / geometry.size.width)) * playback.duration)
                })
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

/// The line being said, over the bottom of the video, with who is saying it. A long line
/// is shown a sentence or so at a time, so the caption keeps pace with the speech instead
/// of putting a paragraph over the picture.
private struct Caption: View {
    let lines: [Utterance]
    let meName: String?
    let playback: Playback

    var body: some View {
        if let index = playback.currentLine, lines.indices.contains(index) {
            let line = lines[index]
            VStack(spacing: 2) {
                Text(Wording.label(line.speaker, me: meName))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RecordingPage.colour(line.speaker))
                Text(Wording.caption(of: line, at: playback.position))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .combine)
        }
    }
}

/// The running time over the video.
private struct PlayheadClock: View {
    let playback: Playback
    var body: some View { Text(Wording.clock(playback.position)) }
}

/// "12:41 / 38:12" beside the play button.
private struct PlayheadTime: View {
    let playback: Playback

    var body: some View {
        (Text(Wording.clock(playback.position)).fontWeight(.semibold)
            + Text(" / \(Wording.clock(playback.duration))").foregroundColor(.secondary))
            .font(.system(size: 12).monospacedDigit())
    }
}

/// Which lines the transcript shows: all of them, or one speaker's, with how many each has.
/// The lines nobody claimed read as "Not sure who", as the People panel calls them.
private struct TranscriptFilter: View {
    let lines: [Utterance]
    let meName: String?
    @Binding var filter: Speaker?

    var body: some View {
        var counts: [Speaker: Int] = [:]
        var order: [Speaker] = []
        for line in lines {
            if counts[line.speaker] == nil { order.append(line.speaker) }
            counts[line.speaker, default: 0] += 1
        }
        let speakers = order.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
        return Menu {
            Picker("Show", selection: $filter) {
                Text("All Lines").tag(Speaker?.none)
                Divider()
                ForEach(speakers, id: \.self) { speaker in
                    Text("\(name(speaker)) (\(counts[speaker] ?? 0))").tag(Speaker?.some(speaker))
                }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Label(filter.map(name) ?? "All Lines",
                  systemImage: filter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Show only one person's lines")
        .accessibilityLabel("Show lines from")
    }

    private func name(_ speaker: Speaker) -> String {
        speaker == .others ? "Not sure who" : Wording.label(speaker, me: meName)
    }
}

private struct TrackChip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).frame(height: 22)
                .background(on ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05), in: Capsule())
                .foregroundStyle(on ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A 32 pt outlined button, for the one action a card offers before it has content.
private struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).frame(height: 32)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Highlights under the pointer, as a menu row does.
private struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    hovering || configuration.isPressed ? Color.primary.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
        }
    }
}

private extension View {
    /// The 14 pt-radius card the summary and player sit in: a grey fill on the white page.
    func card() -> some View {
        background(Color(nsColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Its children on one row, the last one at the trailing edge, when they fit at their ideal
/// widths; otherwise each on a row of its own. Measured from one set of children, so a
/// resize costs arithmetic rather than a second layout.
private struct WrappingRow: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    private func fits(_ sizes: [CGSize], in width: CGFloat?) -> Bool {
        guard let width else { return true }
        return sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1)) <= width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        if fits(sizes, in: proposal.width) {
            let natural = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1))
            return CGSize(width: proposal.width ?? natural, height: sizes.map(\.height).max() ?? 0)
        }
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0,
                      height: sizes.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(0, sizes.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        if fits(sizes, in: bounds.width) {
            let height = sizes.map(\.height).max() ?? 0
            var x = bounds.minX
            for (index, subview) in subviews.enumerated() {
                let last = index == subviews.count - 1 && subviews.count > 1
                let origin = CGPoint(x: last ? bounds.maxX - sizes[index].width : x,
                                     y: bounds.minY + (height - sizes[index].height) / 2)
                subview.place(at: origin, proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + spacing
            }
        } else {
            var y = bounds.minY
            for (index, subview) in subviews.enumerated() {
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(sizes[index]))
                y += sizes[index].height + rowSpacing
            }
        }
    }
}

/// A card's header: title, actions, and an optional note. All three on one row (title, note,
/// then the actions at the trailing edge) when they fit; otherwise the note goes under the
/// title, wrapping to the width, and the actions stay on the title's row.
private struct HeaderRow: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    private func measure(_ subviews: Subviews) -> (title: CGSize, actions: CGSize, note: CGSize?) {
        (subviews[0].sizeThatFits(.unspecified), subviews.count > 1 ? subviews[1].sizeThatFits(.unspecified) : .zero,
         subviews.count > 2 ? subviews[2].sizeThatFits(.unspecified) : nil)
    }

    private func oneRow(_ sizes: (title: CGSize, actions: CGSize, note: CGSize?), width: CGFloat?) -> Bool {
        guard let width else { return true }
        let note = sizes.note.map { $0.width + spacing } ?? 0
        return sizes.title.width + note + spacing + sizes.actions.width <= width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let sizes = measure(subviews)
        let first = max(sizes.title.height, sizes.actions.height)
        if oneRow(sizes, width: proposal.width) {
            let natural = sizes.title.width + (sizes.note.map { $0.width + spacing } ?? 0) + spacing + sizes.actions.width
            return CGSize(width: proposal.width ?? natural, height: max(first, sizes.note?.height ?? 0))
        }
        let width = proposal.width ?? max(sizes.title.width + spacing + sizes.actions.width, sizes.note?.width ?? 0)
        let note = subviews.count > 2 ? subviews[2].sizeThatFits(ProposedViewSize(width: width, height: nil)).height : 0
        return CGSize(width: width, height: first + (subviews.count > 2 ? rowSpacing + note : 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let sizes = measure(subviews)
        let first = max(sizes.title.height, sizes.actions.height)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (first - sizes.title.height) / 2),
                          proposal: ProposedViewSize(sizes.title))
        if subviews.count > 1 {
            subviews[1].place(at: CGPoint(x: bounds.maxX - sizes.actions.width, y: bounds.minY + (first - sizes.actions.height) / 2),
                              proposal: ProposedViewSize(sizes.actions))
        }
        guard subviews.count > 2, let note = sizes.note else { return }
        if oneRow(sizes, width: bounds.width) {
            subviews[2].place(at: CGPoint(x: bounds.minX + sizes.title.width + spacing, y: bounds.minY + (first - note.height) / 2),
                              proposal: ProposedViewSize(note))
        } else {
            subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + first + rowSpacing),
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}
