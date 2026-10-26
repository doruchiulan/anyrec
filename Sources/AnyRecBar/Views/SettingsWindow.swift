import AnyRecKit
import ServiceManagement
import SwiftUI

/// The settings that do not belong in a panel you opened to press one button, and setting
/// a transcription engine up — which was a terminal job until this existed, and so
/// unreachable for anyone who installed only the app.
///
/// A Mac settings window: a toolbar of panes, each a grouped form of the system's own
/// controls, titled by its pane, reopened on the pane last used.
struct SettingsWindow: View {
    @Bindable var controller: RecordingController
    @AppStorage("settingsPane") private var pane = Pane.general

    enum Pane: String {
        case general, recording, transcription, summaries
    }

    var body: some View {
        TabView(selection: $pane) {
            GeneralSettings(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Pane.general)
            RecordingSettings(controller: controller)
                .tabItem { Label("Recording", systemImage: "record.circle") }
                .tag(Pane.recording)
            TranscriptionSettings(controller: controller)
                .tabItem { Label("Transcription", systemImage: "text.bubble") }
                .tag(Pane.transcription)
            SummarySettings(controller: controller)
                .tabItem { Label("Summaries", systemImage: "sparkles") }
                .tag(Pane.summaries)
        }
        .frame(width: 540)
        .task {
            if UserDefaults.standard.string(forKey: "settingsPane") == "speakers" { pane = .transcription }
            await controller.refreshProviders()
        }
    }
}

// MARK: Panes

struct GeneralSettings: View {
    @Bindable var controller: RecordingController
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var loginFailure: String?

    var body: some View {
        SettingsPane {
            Section {
                Toggle("Open at login", isOn: Binding(get: { atLogin }, set: setLogin))
                Toggle("Show in menu bar", isOn: $controller.showsMenuBarExtra)
                Toggle("Record from anywhere with ⇧⌘R", isOn: $controller.shortcut)
            } footer: {
                if let loginFailure { Notice(loginFailure, level: .error) }
            }
            Section {
                Toggle("Offer to record when a call starts", isOn: $controller.offerToRecord)
            } footer: {
                Text("Record from the reminder above a Slack or Teams call window. Notifications for other apps open the window picker.")
                    .settingsFooter()
            }
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            atLogin = on
            loginFailure = nil
        } catch {
            atLogin = SMAppService.mainApp.status == .enabled
            loginFailure = "Couldn't change it: \(error.localizedDescription)"
        }
    }
}

struct RecordingSettings: View {
    @Bindable var controller: RecordingController

    var body: some View {
        SettingsPane {
            Section {
                RecordingInputSettings(controller: controller)
                Toggle("Record system audio", isOn: $controller.configuration.systemAudio)
                if !controller.ffmpegReady {
                    LabeledContent {
                        SetupControl(controller: controller, target: .ffmpeg, size: FFmpegSetup.downloadSize) {
                            controller.installFFmpeg()
                        }
                    } label: {
                        Text("ffmpeg")
                        Text("Makes call.mp4 and the mix the transcript is made from.")
                    }
                }
            } footer: {
                Text("The three tracks are kept as recorded; call.mp4 is one playable file made from them.")
                    .settingsFooter()
            }
            Section("Storage") {
                LabeledContent("Recordings folder") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(
                            URL(fileURLWithPath: controller.configuration.outputRoot.expandingTilde))
                    }
                }
                LabeledContent("Used", value: "\(Wording.size(RecordingLibrary.size(of: controller.library))) in \(Wording.count(controller.library.count))")
                LabeledContent("Available", value: Wording.size(controller.freeSpace))
            }
        }
    }
}

/// Nothing here downloads anything until it is pressed, and what it will fetch and how
/// big that is are on the button.
struct TranscriptionSettings: View {
    @Bindable var controller: RecordingController

    var body: some View {
        SettingsPane(scrollable: true) {
            Section {
                Toggle("Transcribe when a recording ends", isOn: $controller.transcribesOnStop)
                Picker("Engine", selection: $controller.transcriptionMode) {
                    ForEach(TranscriptionMode.allCases, id: \.self) { mode in
                        Text(mode.name).tag(mode)
                            .selectionDisabled(isDisabled(mode))
                    }
                }
                .disabled(!controller.transcribesOnStop)
            }
            EngineSettings(controller: controller)
            AggregatorSettings(controller: controller)
            TranscriptReviewSettings(controller: controller)
            SpeakerSettings(controller: controller)
            if let failure = controller.setupFailure { Notice(failure, level: .error) }
        }
    }

    private func isDisabled(_ mode: TranscriptionMode) -> Bool {
        guard case .engine(let engine) = mode, engine != .auto else { return false }
        return !controller.transcriptionOptions.enabledEngines.contains(engine)
    }
}

struct SummarySettings: View {
    @Bindable var controller: RecordingController

    private static let languages = [
        "English", "Romanian", "German", "French", "Spanish", "Italian", "Portuguese", "Dutch",
    ]

    var body: some View {
        SettingsPane {
            Section {
                Toggle("Summarize after transcribing", isOn: $controller.summarizes)
                Picker("Language", selection: $controller.summaryLanguage) {
                    Text("Same as the call").tag(String?.none)
                    Divider()
                    ForEach(Self.languages, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
            Section {
                Picker("Summarize with", selection: Binding(
                    get: { controller.activeSummaryProvider },
                    set: { controller.summaryProvider = $0 })
                ) {
                    ForEach(SummaryProvider.allCases, id: \.self) { provider in
                        VStack(alignment: .leading) {
                            Text(provider.name)
                            Text(controller.providers[provider]?.detail ?? "")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .tag(SummaryProvider?.some(provider))
                        .selectionDisabled(!controller.canSummarize(with: provider))
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("The transcript text — never the audio — is sent to the provider you choose: Anthropic for Claude Code, OpenAI for Codex and the API, Google for Gemini. Providers that aren't installed can't be chosen.")
                    .settingsFooter()
            }
        }
    }
}


extension Text {
    func settingsFooter() -> some View {
        font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
