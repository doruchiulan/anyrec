import AppKit
import SwiftUI
import AnyRecKit

struct SetupPanel: View {
    @Bindable var controller: RecordingController
    let open: (URL?) -> Void

    var body: some View {
        if controller.canSeeScreen {
            VStack(alignment: .leading, spacing: 12) {
                start
                advisory
                if let failure = controller.failure { Notice(failure, level: .error) }
                if let updates = controller.updates, let version = updates.available {
                    MenuRow(Wording.updateAvailable(version), action: { updates.checkForUpdates() }) {
                        Text("Update…")
                    }
                }
                recent
            }
        } else {
            PermissionPanel(controller: controller)
        }
    }

    /// A detected call comes first, with its own Record buttons, and macOS's picker moves
    /// to Other Window…. With no call, the two picker commands are the whole choice.
    @ViewBuilder private var start: some View {
        if controller.ongoingCalls.isEmpty {
            pickerButtons
        } else {
            OngoingCallsChooser(controller: controller)
        }
    }

    /// Two commands, not a switch and a button: which one is pressed is the whole choice,
    /// and pressing either opens the picker straight away.
    private var pickerButtons: some View {
        VStack(spacing: 6) {
            Button { controller.pickAndStart() } label: {
                Label(title(video: true), systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!controller.canStart)
            .help(Wording.recordHelp(video: true))
            Button { controller.pickAndStart(video: false) } label: {
                Label(title(video: false), systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!controller.canStartAudioOnly)
            .help(Wording.recordHelp(video: false))
        }
    }

    /// "Starting…" on whichever of the two was pressed.
    private func title(video: Bool) -> String {
        controller.phase == .starting && controller.configuration.video == video
            ? "Starting…" : Wording.record(video: video)
    }

    @ViewBuilder private var advisory: some View {
        if let advisory = controller.advisory, advisory != .speakersNotSetUp {
            VStack(alignment: .leading, spacing: 4) {
                Notice(Wording.advisory(advisory))
                if advisory == .accessibilityMissing {
                    Button("Open Privacy & Security…") {
                        NSWorkspace.shared.open(Permission.accessibility.settingsURL)
                    }
                    .buttonStyle(.link).font(.callout)
                }
            }
        }
    }

    @ViewBuilder private var recent: some View {
        if !controller.library.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 8)
                ForEach(controller.library.prefix(3)) { entry in
                    MenuRow(Wording.title(of: entry), action: { open(entry.directory) }) {
                        Text(Wording.when(entry)).monospacedDigit()
                    }
                }
            }
        }
    }
}

/// The detected calls, each with its own Record buttons, then Other Window… for macOS's
/// picker. The menu bar panel shows it in place of its two picker buttons; the library
/// window's record buttons show it in a popover (`NewRecordingButton`). `chose` runs after
/// any of its buttons, so a popover can close.
struct OngoingCallsChooser: View {
    @Bindable var controller: RecordingController
    var chose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Wording.ongoingCalls(controller.ongoingCalls.count))
                .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 8)
            ForEach(controller.ongoingCalls) { call in
                OngoingCallRow(call: call, controller: controller, chose: chose)
            }
            VStack(alignment: .leading, spacing: 2) {
                MenuRow(Wording.otherWindow(video: true), action: { chose(); controller.pickAndStart() })
                    .disabled(!controller.canStart)
                    .help(Wording.recordHelp(video: true))
                MenuRow(Wording.otherWindow(video: false), action: { chose(); controller.pickAndStart(video: false) })
                    .disabled(!controller.canStartAudioOnly)
                    .help(Wording.recordHelp(video: false))
            }
        }
    }
}

/// The library window's record button. With no call detected it opens macOS's picker, as
/// before; with one, it first offers the call (`OngoingCallsChooser`) in a popover, the
/// same choice the menu bar panel makes.
struct NewRecordingButton<Content: View>: View {
    @Bindable var controller: RecordingController
    @ViewBuilder let label: () -> Content
    @State private var choosing = false

    var body: some View {
        Button {
            if controller.ongoingCalls.isEmpty { controller.pickAndStart() } else { choosing = true }
        } label: {
            label()
        }
        .help(controller.ongoingCalls.isEmpty ? "Choose a window and start recording" : "Record the call, or choose another window")
        .disabled(!controller.canStart)
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            OngoingCallsChooser(controller: controller) { choosing = false }
                .padding(12)
                .frame(width: 320)
        }
    }
}

/// One detected call window: the app's icon, the window's title and the app, and the two
/// ways to record it. Pressing either starts at once, with no picker.
private struct OngoingCallRow: View {
    let call: OngoingCall
    @Bindable var controller: RecordingController
    var chose: () -> Void = {}

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(nsImage: icon).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(call.title ?? call.app.name).font(.headline).lineLimit(2)
                        if call.title != nil {
                            Text(call.app.name).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Button { chose(); controller.record(call, video: true) } label: {
                        Label(title(video: true), systemImage: "record.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canStart)
                    Button { chose(); controller.record(call, video: false) } label: {
                        Label(title(video: false), systemImage: "waveform").frame(maxWidth: .infinity)
                    }
                    .disabled(!controller.canStartAudioOnly)
                }
                .controlSize(.large)
            }
            .padding(4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(call.app.name) call\(call.title.map { ", \($0)" } ?? "")")
    }

    /// "Starting…" on whichever was pressed, while this call is what is starting.
    private func title(video: Bool) -> String {
        controller.phase == .starting && controller.configuration.video == video
            && controller.configuration.capture == call.choice
            ? "Starting…" : Wording.recordCall(video: video)
    }

    private var icon: NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: call.app.bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "phone.fill", accessibilityDescription: nil) ?? NSImage()
    }
}
