import AppKit
import Foundation
import Observation
import AnyRecKit

/// Everything the menu bar shows, and the one recording it drives. Owned by the app
/// delegate rather than by a view: the panel closes the moment you click away, and a
/// recording has to outlive that.
@MainActor
@Observable
final class RecordingController {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case stopping
        case transcribing
        case finished
    }

    /// Opens on what the last launch left, and on Automatic the first time: someone who
    /// put a recorder in their menu bar wants the transcript too, and `auto` is the
    /// setting that never leaves the machine.
    var configuration: RecordingConfiguration = {
        var configuration = RecordingConfiguration()
        Preferences.loaded(into: &configuration)
        return configuration
    }() {
        didSet { Preferences.save(configuration) }
    }

    private(set) var phase = Phase.idle
    private(set) var readiness = Readiness(appleLanguages: [])
    private(set) var microphones: [AudioInputDevice] = []
    private(set) var outcome: RecordingOutcome?
    private(set) var transcript: TranscriptOutcome?
    /// Something about the recording that outlives it — the microphone being denied,
    /// say. Kept apart from `progress`, which is overwritten many times a second.
    private(set) var note: String?
    private(set) var progress: String?
    private(set) var failure: String?
    private(set) var canSeeScreen = Permissions.screenRecordingGranted()

    /// What the settings window is doing, and what it last did. Kept apart from the
    /// recording's own `progress` and `failure`: an install runs while a recording does.
    private(set) var setupProgress: String?
    private(set) var setupFailure: String?
    private(set) var keyOutcome: OpenAIKey.StoreOutcome?

    /// Bumped by the ticker so the meters redraw; the levels themselves are read
    /// straight off the buffers on their way to disk.
    private(set) var tick = Date()

    /// Held as text rather than derived from `tick`, so the menu bar item redraws once
    /// a second instead of ten times.
    private(set) var clock = ""

    private(set) var session: RecordingSession?
    private var ticker: Task<Void, Never>?
    private var setup: Task<Void, Never>?
    private var askedForScreen = false
    private let picker = SystemPicker()

    var isSettingUp: Bool { setupProgress != nil }

    var isRecording: Bool { phase == .recording || phase == .stopping }
    var advisory: Advisory? { readiness.advisory(for: configuration) }

    var canStart: Bool { phase == .idle }

    /// Both of these are slow — the first device enumeration cold-starts AVFoundation —
    /// so they are asked for once at launch rather than when the panel is opened.
    func prepare() async {
        async let probe = Readiness.probe()
        let inputs = await Task.detached { AudioDevices.inputs() }.value

        microphones = inputs
        configuration.microphone = Preferences.microphone(among: inputs)
        configuration.pinDefaultMicrophone(from: inputs)
        readiness = await probe
    }

    /// Input devices come and go while the panel is shut — this app runs for days and
    /// the AirPods go in halfway through one — so the list is asked for again every
    /// time it is shown.
    ///
    /// The selection is re-read from that list rather than merely checked against it:
    /// a device whose `isDefault` has moved is the same device, but it is not the same
    /// *value*, and a menu matching on the whole value would draw itself empty. A
    /// device that has gone falls out to nil, which is Off.
    ///
    /// `pinDefaultMicrophone` is deliberately not re-run here: once someone has used
    /// the menu, nil means Off, and re-pinning would quietly undo them.
    func refresh() async {
        guard phase == .idle else { return }

        /// Before the Screen Recording gate: listing inputs needs no grant, so a denied
        /// screen must not hide the microphones too.
        microphones = await Task.detached { AudioDevices.inputs() }.value
        if let chosen = configuration.microphone {
            configuration.microphone = microphones.first { $0.id == chosen.id }
        }

        canSeeScreen = Permissions.screenRecordingGranted()
    }

    /// Setting an engine up outlives the window it was started from — a settings window
    /// closes the moment you click away from it, and `brew install` does not — so the
    /// task belongs here, with everything else the app delegate owns.
    func installWhisper() {
        guard setup == nil else { return }
        setupFailure = nil

        setup = Task {
            for step in WhisperSetup.pending() {
                setupProgress = step.title
                do {
                    try await WhisperSetup.perform(step) { line in
                        Task { @MainActor in self.setupProgress = "\(step.title) — \(line)" }
                    }
                } catch {
                    setupFailure = "\(error)"
                    break
                }
            }
            /// Whisper can be installed from here mid-session, so what the panel says
            /// about the engines has to be asked again rather than left at launch.
            readiness = await Readiness.probe()
            setupProgress = nil
            setup = nil
        }
    }

    /// The key is handed straight to the Kit, which checks it against the API before
    /// writing it and never gives it back. Nothing here keeps a copy.
    func saveOpenAIKey(_ key: String) async {
        keyOutcome = nil
        let outcome = await OpenAIKey.validateAndStore(key)
        readiness = await Readiness.probe()
        keyOutcome = outcome
    }

    /// Asked once a launch, the first time the panel has to say the screen is off. Only
    /// asking registers the app with TCC, and until it has there is no AnyRec row in
    /// Privacy & Security to switch on — which left the panel pointing at a list the app
    /// was not in, and the only way through it the `+` button.
    func requestScreenRecording() async {
        guard !canSeeScreen, !askedForScreen else { return }
        askedForScreen = true
        canSeeScreen = await Permissions.requestScreenRecording()
    }

    /// Pointing at a window *is* starting the recording. Picking on its own row meant
    /// two decisions to reach one recording, and left a pick to go stale between them;
    /// this way what is recorded is whatever was pointed at a moment ago. Closing the
    /// picker without choosing records nothing, which is what closing it means.
    func pickAndStart() {
        guard phase == .idle else { return }
        picker.present { [weak self] choice in
            guard let self, let choice else { return }
            configuration.capture = choice
            Task { await self.start() }
        }
    }

    func start() async {
        guard phase == .idle, configuration.capture != nil else { return }
        phase = .starting
        failure = nil
        outcome = nil
        transcript = nil
        note = nil
        progress = nil
        clock = Wording.clock(0)

        if configuration.microphone != nil, await !Permissions.requestMicrophone() {
            configuration.microphone = nil
            note = "Microphone access was denied, so this was recorded without it."
        }

        do {
            session = try await RecordingSession.start(configuration)
            phase = .recording
            startTicking()
        } catch {
            failure = "\(error)"
            phase = .idle
        }
    }

    func stop() async {
        guard let session, phase == .recording else { return }
        phase = .stopping
        stopTicking()

        do {
            outcome = try await session.stop()
        } catch {
            /// Nothing was closed properly, so there is nothing to transcribe over.
            failure = "\(error)"
            phase = .finished
            return
        }

        guard session.configuration.transcribe != nil else {
            phase = .finished
            return
        }
        phase = .transcribing
        transcript = await session.transcript { line in
            Task { @MainActor in self.progress = line }
        }
        progress = nil
        phase = .finished
    }

    /// Back to the setup panel, keeping the settings that produced the last recording.
    func dismiss() {
        guard phase == .finished else { return }
        session = nil
        phase = .idle
    }

    /// A quit mid-recording would leave three files with no moov atom, which nothing
    /// can open. Terminating waits for the writers to finalise, exactly as the
    /// terminal's signal handling does.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard phase == .recording || phase == .starting else { return .terminateNow }
        Task {
            /// Quitting while the stream is still coming up would reply before there
            /// is anything to stop, and the recording would start into a dying app.
            while phase == .starting {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func startTicking() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let session else { return }
                tick = Date()
                if clock != Wording.clock(session.elapsed) {
                    clock = Wording.clock(session.elapsed)
                }
                if session.reachedDeadline { await stop() }
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }
}
