import AVKit
import AnyRecKit
import SwiftUI

/// One recording, and the player for it. The player is made when a recording is opened,
/// never in `init`: a view's `init` runs on every redraw of its parent, and a player made
/// there was a new `AVPlayer`, a new time observer and a fresh decode of the whole call's
/// audio each time the list filtered or the library reloaded.
struct RecordingDetail: View {
    @Bindable var controller: RecordingController
    let entry: LibraryEntry
    @Binding var showsInspector: Bool
    @Binding var strip: ToolbarStrip
    @State private var playback: Playback?

    var body: some View {
        Group {
            if let playback, playback.entry.directory == entry.directory {
                RecordingPage(
                    controller: controller, entry: entry, playback: playback,
                    showsInspector: $showsInspector, strip: $strip
                )
                .focusedSceneValue(\.playback, playback)
            } else {
                Color.clear
            }
        }
        .task(id: entry.video ?? entry.directory) {
            playback?.stop()
            let opened = Playback(entry)
            playback = opened
            await opened.loadWaveform()
        }
        .onDisappear { playback?.stop() }
    }
}

/// One recording: the video, its summary and who spoke, with what was said — the
/// transcript, the tracks and the files — in the inspector beside it, so the transcript
/// stays in view while the video plays. Reads the files
/// the Kit left in the folder; the only things it writes are voice names (through
/// `VoiceNaming`, so the library learns them) and ticks on a summary's action items.
///
/// Nothing in this body reads the playhead. It moves ten times a second, and whatever
/// reads it is redrawn as often — so the clock, the waveform and the transcript's
/// highlight are views of their own, and this page is redrawn when it actually changes.
private struct RecordingPage: View {
    @Bindable var controller: RecordingController
    let entry: LibraryEntry
    let playback: Playback
    @Binding var showsInspector: Bool
    /// Owned by the library window, not here: measured widths that started from zero
    /// for every recording opened sent the buttons on a visible walk from the trailing
    /// edge each time the selection changed.
    @Binding var strip: ToolbarStrip

    @State private var transcript: Transcript?
    @State private var voices: RecordingVoices?
    @State private var summary: Summary?
    @State private var legacySummary: String?
    @State private var names: [String: String] = [:]
    @State private var tab = Tab.transcript
    @State private var popout: NSWindow?
    /// The transcript with names in, worked out when it loads rather than on each redraw.
    @State private var lines: [Utterance] = []
    @State private var tabsProbe = ToolbarProbe.Box()
    @State private var buttonsProbe = ToolbarProbe.Box()
    @State private var look: Task<Void, Never>?
    @State private var looks = 0

    /// The inspector's frame comes from SwiftUI, which lays the content out and so knows
    /// it; applied on the next turn of the run loop, never inside the layout pass that
    /// produced it (see `ToolbarStrip`). Then the strip is looked at.
    private func inspectorMoved(_ frame: CGRect) {
        guard strip.active else { return }
        Task { @MainActor in
            strip.inspectorMoved(to: frame)
            lookSoon(fresh: true)
        }
    }

    /// The toolbar's items are read where they really are, from their views, 300 ms
    /// after anything changed — the toolbar moves them itself, after SwiftUI has laid
    /// them out, so SwiftUI's geometry for them is stale — and again while the strip
    /// still asks, a few times at most.
    private func lookSoon(fresh: Bool = false) {
        if fresh { looks = 0 }
        look?.cancel()
        guard strip.active, looks < 6 else { return }
        look = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            looks += 1
            guard let tabs = tabsProbe.frameInWindow, let buttons = buttonsProbe.frameInWindow
            else { return }
            if strip.observe(tabs: tabs, buttons: buttons) { lookSoon() }
        }
    }

    enum Tab: String, CaseIterable { case transcript = "Transcript", tracks = "Tracks", files = "Files" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ProcessingStatusView(controller: controller, directory: entry.directory)
                if entry.video != nil || !playback.available.isEmpty { playerCard }
                TranscriptReviewDetails(directory: entry.directory).id(entry.transcript)
                SpeakerReviewSuggestions(controller: controller, entry: entry).id(entry.transcript)
                if transcript != nil { summaryCard.disabled(controller.processing.working.contains(entry.directory)) }
                if let voices, !voices.unnamed.isEmpty { naming(voices).disabled(controller.working.contains(entry.directory)) }
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        /// White, like a document; the cards sit on it in a soft grey. Both are system
        /// colours, so Dark Mode turns them into near-black and a lifted grey.
        .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea())
        /// Floats over the page's top-right corner, in the row the window's controls use,
        /// rather than holding a toolbar row of its own.
        .toolbar { actions }
        .inspector(isPresented: $showsInspector) {
            inspector
                .inspectorColumnWidth(min: 300, ideal: 400, max: 600)
        }
        .onChange(of: showsInspector, initial: true) {
            strip.active = showsInspector
            lookSoon(fresh: true)
        }
        .task { load() }
        .onChange(of: entry) { load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Wording.title(of: entry)).font(.system(size: 18, weight: .semibold))
                Text(Wording.meta(of: entry)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// The page's actions, as toolbar items so the system floats them in Liquid Glass and
    /// they stay put while the page scrolls: the two that act on its files grouped, the
    /// inspector in a group of its own.
    ///
    /// The window's toolbar is one strip across the recording and the inspector, with no
    /// way to say "the end of this column". So everything is pushed to the trailing end
    /// and walked back by two invisible items whose widths are measured: `gap` holds
    /// these at the recording's edge, `pad` centres the inspector's tabs over it.
    @ToolbarContentBuilder private var actions: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { controller.reveal(entry) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("Show in Finder")
            if let video = entry.video {
                ShareLink(item: video).help("Share")
            }
        }
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showsInspector.toggle() } label: {
                Label("Inspector", systemImage: "info")
            }
            .help(showsInspector ? "Hide the transcript, tracks and files" : "Show the transcript, tracks and files")
            .overlay(ToolbarProbe(buttonsProbe).allowsHitTesting(false))
        }
        if showsInspector {
            if #available(macOS 26, *) {
                ToolbarItem(placement: .primaryAction) { strip.gapItem }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { strip.gapItem }
            }
        }
    }

    // MARK: Player

    private var playerCard: some View {
        VStack(spacing: 12) {
            if entry.video != nil {
                ZStack(alignment: .topTrailing) {
                    VideoSurface(player: playback.player)
                        .aspectRatio(aspect, contentMode: .fit)
                        .frame(maxHeight: 380)
                        .opacity(playback.enabled.contains(.video) ? 1 : 0)
                        .background(Color(white: 0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity)
                    if controller.showsCaptions, !lines.isEmpty {
                        Caption(lines: lines, playback: playback)
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
                    .help("Open in its own window, with Picture in Picture")
                    .accessibilityLabel("Open in its own window")
                }
            }
            WaveformBar(playback: playback).frame(height: 44)
            controls
        }
        .padding(14)
        .card()
    }

    private var aspect: CGFloat {
        guard let info = entry.info, info.height > 0 else { return 16 / 10 }
        return CGFloat(info.width) / CGFloat(info.height)
    }

    private var controls: some View {
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
            Spacer()
            Text("Tracks").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(playback.available, id: \.self) { track in
                TrackChip(
                    title: Wording.trackName(track), on: playback.enabled.contains(track)
                ) { playback.set(track, on: !playback.enabled.contains(track)) }
            }
        }
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
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text("Summary").font(.system(size: 13, weight: .semibold))
                if let provider {
                    Text("\(summary?.provider ?? provider.name) · from the transcript")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if summary != nil || legacySummary != nil {
                    Button { copy(summary?.markdown ?? legacySummary ?? "") } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy summary").accessibilityLabel("Copy summary")
                    providerMenu
                    Button { controller.summarize(entry) } label: { Image(systemName: "arrow.clockwise") }
                        .help("Regenerate summary").accessibilityLabel("Regenerate summary")
                        .disabled(busy)
                }
            }
            .buttonStyle(.borderless)

            if busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Summarising…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if let summary {
                structured(summary)
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
        guard var summary, let url = entry.summary, url.pathExtension == "json" else { return }
        summary.actions[index].done = done
        try? summary.write(to: url)
        self.summary = summary
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Naming

    private func naming(_ voices: RecordingVoices) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Who's speaking?").font(.system(size: 13, weight: .semibold))
                Text("Name these voices once and AnyRec recognises them on your next call.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
                ForEach(voices.unnamed, id: \.letter) { voice in
                    SpeakerNamingCard(voice: voice, name: binding(voice.letter),
                                      suggestion: TranscriptReview.read(in: entry.directory)?.suggestions.first { $0.letter == voice.letter },
                                      colour: Self.colour(.voice(voice.letter))) {
                        playback.play(from: voice.start)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Not now") { names = [:] }.buttonStyle(.borderless)
                Button("Save names") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(names.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func binding(_ letter: String) -> Binding<String> {
        Binding(get: { names[letter] ?? "" }, set: { names[letter] = $0 })
    }

    private func save() {
        let given = names.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !given.isEmpty else { return }
        if let result = try? VoiceNaming.apply(given, in: entry.directory) {
            voices = result.voices
            names = [:]
            named()
            controller.reloadPeople()
            Task { await controller.reloadLibrary() }
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            if tab == .transcript, transcript != nil {
                HStack { Spacer(); TranscriptAction(controller: controller, entry: entry) }.padding(12)
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            inspectorMoved(frame)
        }
        /// In the toolbar's row over the inspector rather than a row of its own under it,
        /// centred over it by the trailing `pad`. Only while the inspector is shown: a
        /// collapsed inspector still contributes its toolbar items, and its tabs would
        /// stay in the strip with nothing under them.
        .toolbar {
            if showsInspector {
            ToolbarItem(placement: .automatic) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .overlay(ToolbarProbe(tabsProbe).allowsHitTesting(false))
            }
            if #available(macOS 26, *) {
                ToolbarItem(placement: .automatic) { strip.padItem }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .automatic) { strip.padItem }
            }
            }
        }
    }

    @ViewBuilder private var transcriptLines: some View {
        if transcript != nil {
            TranscriptList(lines: lines, playback: playback)
        } else {
            TranscriptPlaceholder(controller: controller, entry: entry)
        }
    }

    /// The three masters, each with what it is, how big, and a switch for hearing it.
    private var tracks: some View {
        let plan = OutputPlan(directory: entry.directory)
        let rows: [(Playback.Track, URL)] = [
            (.video, plan.screen), (.callAudio, plan.systemAudio), (.microphone, plan.microphone),
        ]
        return VStack(spacing: 0) {
            ForEach(rows.filter { FileManager.default.fileExists(atPath: $0.1.path) }, id: \.1) { track, url in
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Wording.trackName(track)).font(.system(size: 13))
                        Text(url.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Wording.size(Wording.bytes(of: url))).font(.system(size: 11)).foregroundStyle(.secondary)
                    Toggle("", isOn: Binding(
                        get: { playback.enabled.contains(track) }, set: { playback.set(track, on: $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .accessibilityLabel("Play \(Wording.trackName(track))")
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
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: entry.directory, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? []
        return VStack(spacing: 0) {
            ForEach(urls.sorted { $0.lastPathComponent < $1.lastPathComponent }, id: \.self) { url in
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    HStack {
                        Text(url.lastPathComponent).font(.system(size: 13))
                        Spacer()
                        Text(Wording.size(Wording.bytes(of: url))).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).frame(height: 32).contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
            }
        }
    }

    // MARK: Loading

    private func load() {
        transcript = entry.transcript.flatMap(Transcript.read)
        voices = RecordingVoices.read(in: entry.directory)
        named()
        summary = nil
        legacySummary = nil
        if let url = entry.summary {
            if url.pathExtension == "json" {
                summary = Summary.read(url)
            } else {
                legacySummary = try? String(contentsOf: url, encoding: .utf8)
            }
        }
    }

    private func named() {
        lines = transcript?.named(voices?.names ?? [:]).utterances ?? []
        playback.follow(transcript)
    }

    /// Me is the accent; everyone else gets a fixed hue per letter so a voice keeps its
    /// colour down the page and across recordings.
    static func colour(_ speaker: Speaker) -> Color {
        switch speaker {
        case .me: return .accentColor
        case .others: return .purple
        case .voice(let letter), .named(let letter):
            let palette: [Color] = [.purple, .orange, .teal, .pink, .indigo, .mint]
            return palette[Int(letter.unicodeScalars.reduce(0) { $0 + $1.value }) % palette.count]
        }
    }
}

/// The two spacer widths that put the toolbar's items where they belong, and the
/// measurements they are worked out from.
///
/// The widths depend only on how wide the inspector and the tabs are, plus a constant
/// each for the toolbar's own insets and spacing: `pad` centres the tabs, so it is half
/// the inspector less half the tabs less that constant, and `gap` works out the same way.
/// Neither width changes while the window is resized, so nothing moves. The constants
/// are the only thing taken from positions, and the positions have to be real ones: the
/// toolbar moves its items itself after SwiftUI has laid them out, so SwiftUI's geometry
/// for an item is wherever it was last laid out — the tabs reported one x through three
/// changes of `pad` — and the items are read from their views instead, by `ToolbarProbe`,
/// once the strip has had time to settle. An offset is acted on only when two looks
/// 300 ms apart agree on it, so a frame caught mid-move changes nothing.
///
/// A width changed inside the layout pass that measured it is an AppKit exception that
/// took the app down, which is why the inspector's frame, which does come from SwiftUI,
/// is applied a turn of the run loop later.
struct ToolbarStrip {
    /// What is worth keeping between launches: the constants are the toolbar's, the same
    /// every time, and the last widths make the first layout right before anything has
    /// been measured — without them the buttons walked into place over a second.
    struct Memory: Codable, Equatable {
        var padConstant: CGFloat?
        var gapConstant: CGFloat?
        var tabsWidth: CGFloat
        var pad: CGFloat
        var gap: CGFloat
    }

    private(set) var inspector = CGRect.zero
    private(set) var gap: CGFloat = 0
    private(set) var pad: CGFloat = 0
    private var padConstant: CGFloat?
    private var gapConstant: CGFloat?
    /// The offsets the previous look found, for the next one to agree with.
    private var seen: (pad: CGFloat, gap: CGFloat)?
    private var tabsWidth: CGFloat = 0

    init(remembering memory: Memory? = nil) {
        guard let memory else { return }
        padConstant = memory.padConstant
        gapConstant = memory.gapConstant
        tabsWidth = memory.tabsWidth
        pad = memory.pad
        gap = memory.gap
    }

    var memory: Memory {
        Memory(padConstant: padConstant, gapConstant: gapConstant, tabsWidth: tabsWidth, pad: pad, gap: gap)
    }

    /// Off while the inspector is hidden: the strip then has no gap or tabs in it, so
    /// nothing in it says anything about the widths.
    var active = true {
        didSet { if active != oldValue { seen = nil } }
    }

    /// Between the ⓘ's glass and the inspector's edge.
    static let margin: CGFloat = 20

    /// The invisible items themselves. Nothing but width: no glass, no bezel. Never zero
    /// wide: an empty item drops out of the strip along with its spacing.
    var gapItem: some View { Color.clear.frame(width: max(1, gap), height: 1) }
    var padItem: some View { Color.clear.frame(width: max(1, pad), height: 1) }

    /// The inspector's width is what the widths follow; its position only matters to the
    /// constants, which a later look settles.
    mutating func inspectorMoved(to frame: CGRect) {
        inspector = frame
        seen = nil
        guard frame.width > 0, tabsWidth > 0 else { return }
        if let constant = padConstant { settle(&pad, to: half - constant) }
        if let constant = gapConstant { settle(&gap, to: half - constant) }
    }

    private var half: CGFloat { (inspector.width - tabsWidth) / 2 }

    /// Where the tabs and the ⓘ really are. Returns whether another look is wanted: the
    /// widths changed and the toolbar has yet to move, or an offset was seen once and
    /// has to be seen again before it is believed.
    mutating func observe(tabs: CGRect, buttons: CGRect) -> Bool {
        guard active, inspector.width > 0, tabs.width > 0, buttons.width > 0 else { return false }
        tabsWidth = tabs.width
        let padOff = tabs.midX - inspector.midX
        let gapOff = buttons.maxX - (inspector.minX - Self.margin)
        guard padOff.isFinite, gapOff.isFinite else { return false }
        let settled = abs(padOff) <= 0.5 && abs(gapOff) <= 0.5
        if settled {
            if padConstant == nil { padConstant = half - pad }
            if gapConstant == nil { gapConstant = half - gap }
            seen = nil
            return false
        }
        /// A first calibration is taken from the first look; a correction to one that
        /// exists waits for two looks to agree, so a frame caught mid-move changes nothing.
        let calibrated = padConstant != nil && gapConstant != nil
        if calibrated {
            guard let seen, abs(seen.pad - padOff) < 1, abs(seen.gap - gapOff) < 1 else {
                self.seen = (padOff, gapOff)
                return true
            }
        }
        self.seen = nil
        let padBefore = pad
        if abs(padOff) > 0.5 { settle(&pad, to: pad + padOff) }
        padConstant = half - pad
        /// The ⓘ moves with the pad too, so what the pad just took is already spoken for.
        let gapRemaining = gapOff - (pad - padBefore)
        if abs(gapRemaining) > 0.5 { settle(&gap, to: gap + gapRemaining) }
        gapConstant = half - gap
        return true
    }

    /// Neither width can usefully exceed the inspector's: past that the item has left the
    /// strip for the overflow menu, where its position no longer answers to the width.
    private func settle(_ width: inout CGFloat, to wanted: CGFloat) {
        let clamped = min(inspector.width, max(0, wanted))
        if abs(clamped - width) > 0.5 { width = clamped }
    }
}

/// A view of no size over a toolbar item, through which the item's real position in the
/// window is read — from AppKit, which is what moves it.
struct ToolbarProbe: NSViewRepresentable {
    @MainActor final class Box {
        weak var view: NSView?

        /// In the window's coordinates; nil when the item is not on screen, as when the
        /// toolbar has put it in the overflow menu.
        var frameInWindow: CGRect? {
            guard let view, let window = view.window, let parent = view.superview else { return nil }
            let frame = parent.convert(parent.bounds, to: nil)
            return window.contentView.map { $0.convert(frame, from: nil) } ?? frame
        }
    }

    let box: Box
    init(_ box: Box) { self.box = box }

    /// Over the item but never in its way: clicks fall through to the button beneath.
    final class Passthrough: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Passthrough {
        let view = Passthrough(frame: .zero)
        box.view = view
        return view
    }

    func updateNSView(_ view: Passthrough, context: Context) { box.view = view }
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
    let playback: Playback

    var body: some View {
        if let index = playback.currentLine, lines.indices.contains(index) {
            let line = lines[index]
            VStack(spacing: 2) {
                Text(line.speaker.label)
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

/// Every line, laid out only as it scrolls into view, opening at the top and keeping the
/// line being played in view while the recording plays. Each row is told whether it is
/// the one playing, so moving the highlight redraws two rows, not a thousand.
private struct TranscriptList: View {
    let lines: [Utterance]
    let playback: Playback

    var body: some View {
        let current = playback.currentLine
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(lines.indices, id: \.self) { index in
                        TranscriptRow(line: lines[index], isCurrent: index == current) {
                            playback.play(from: lines[index].start)
                        }
                        .equatable()
                        .id(index)
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.top)
            /// Only while playing: a click on a line seeks there, and scrolling away to read
            /// ahead while paused should not be undone.
            .onChange(of: current) { _, line in
                guard playback.isPlaying, let line else { return }
                withAnimation { reader.scrollTo(line, anchor: .center) }
            }
        }
    }
}

private struct TranscriptRow: View, Equatable {
    let line: Utterance
    let isCurrent: Bool
    let play: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.line == b.line && a.isCurrent == b.isCurrent }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(Wording.clock(line.start), action: play)
                .buttonStyle(.plain)
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
                .accessibilityLabel("Play from \(Wording.clock(line.start))")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(RecordingPage.colour(line.speaker)).frame(width: 8, height: 8)
                    Text(line.speaker.label).font(.system(size: 11, weight: .semibold))
                }
                Text(line.text).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
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
