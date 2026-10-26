import AnyRecKit
import SwiftUI

/// The open recording's player, published by the library window so the menu bar can
/// reach it.
struct PlaybackKey: FocusedValueKey {
    typealias Value = Playback
}

extension FocusedValues {
    var playback: Playback? {
        get { self[PlaybackKey.self] }
        set { self[PlaybackKey.self] = newValue }
    }
}

/// Every command the app has, in the menu bar. Mac users learn an app from its menus, and
/// a toolbar can be hidden or customised away, so nothing lives only in a toolbar, a
/// context menu or the menu bar helper. Items that cannot run are dimmed, never hidden.
struct AnyRecCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Bindable var controller: RecordingController
    @FocusedValue(\.playback) private var playback

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Recording…") { controller.pickAndStart() }
                .keyboardShortcut("n")
                .disabled(!controller.canStart)
            Button("Stop Recording") { Task { await controller.stop() } }
                .keyboardShortcut(".")
                .disabled(controller.phase != .recording)
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Show in Finder") { controller.selectedEntry.map(controller.reveal) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(controller.selectedEntry == nil)
            Button("Move to Trash") { controller.selectedEntry.map(controller.trash) }
                .keyboardShortcut(.delete)
                .disabled(controller.selectedEntry == nil)
            Divider()
            Button("Import Voices…") { controller.importVoicesPanel() }
            Button("Export Voices…") { controller.exportVoicesPanel() }
                .disabled(controller.people.isEmpty)
        }

        CommandGroup(after: .help) {
            Button("Welcome to AnyRec…") { openWindow(id: WelcomeSheet.windowID) }
        }

        SidebarCommands()
        InspectorCommands()
        CommandGroup(after: .sidebar) {
            Button(controller.showsCaptions ? "Hide Captions" : "Show Captions") {
                controller.showsCaptions.toggle()
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
        }

        CommandMenu("Playback") {
            Button(playback?.isPlaying == true ? "Pause" : "Play") { playback?.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(playback == nil)
            Button("Skip Back 10 Seconds") { playback?.skip(-10) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(playback == nil)
            Button("Skip Forward 10 Seconds") { playback?.skip(10) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(playback == nil)
            Divider()
            Picker("Speed", selection: Binding(
                get: { playback?.rate ?? 1 }, set: { playback?.rate = $0 })
            ) {
                ForEach(Wording.rates, id: \.self) { Text(Wording.rate($0)).tag($0) }
            }
            .disabled(playback == nil)
        }

        CommandMenu("Recording") {
            Button(controller.selectedEntry?.transcript == nil ? "Generate Transcript…" : "Regenerate Transcript…") {
                controller.transcriptRequest = controller.selectedEntry
            }
            .disabled(controller.selectedEntry.map { !controller.canTranscribe($0) } ?? true)
            Divider()
            Button("Summarize") { controller.selectedEntry.map(controller.summarize) }
                .disabled(!canSummarize)
            Picker("Summarize With", selection: $controller.summaryProvider) {
                ForEach(SummaryProvider.allCases, id: \.self) { provider in
                    Text(provider.name).tag(SummaryProvider?.some(provider))
                        .selectionDisabled(!controller.canSummarize(with: provider))
                }
            }
        }
    }

    private var canSummarize: Bool {
        guard let entry = controller.selectedEntry else { return false }
        return entry.transcript != nil && controller.activeSummaryProvider != nil
            && !controller.summarizing.contains(entry.directory)
    }
}
