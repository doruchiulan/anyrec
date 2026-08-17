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

    var configuration = RecordingConfiguration()

    private(set) var phase = Phase.idle
    private(set) var readiness = Readiness(appleLanguages: [])
    private(set) var microphones: [AudioInputDevice] = []
    private(set) var catalogue: CaptureCatalogue?
    private(set) var outcome: RecordingOutcome?
    private(set) var transcript: TranscriptOutcome?
    /// Something about the recording that outlives it — the microphone being denied,
    /// say. Kept apart from `progress`, which is overwritten many times a second.
    private(set) var note: String?
    private(set) var progress: String?
    private(set) var failure: String?
    private(set) var canSeeScreen = Permissions.screenRecordingGranted()

    /// Bumped by the ticker so the meters redraw; the levels themselves are read
    /// straight off the buffers on their way to disk.
    private(set) var tick = Date()

    /// Held as text rather than derived from `tick`, so the menu bar item redraws once
    /// a second instead of ten times.
    private(set) var clock = ""

    private(set) var session: RecordingSession?
    private var ticker: Task<Void, Never>?

    var isRecording: Bool { phase == .recording || phase == .stopping }
    var advisory: Advisory? { readiness.advisory(for: configuration) }

    var canStart: Bool { configuration.capture != nil && phase == .idle }

    /// Both of these are slow — the first device enumeration cold-starts AVFoundation —
    /// so they are asked for once at launch rather than when the panel is opened.
    func prepare() async {
        async let probe = Readiness.probe()
        let inputs = await Task.detached { AudioDevices.inputs() }.value

        microphones = inputs
        configuration.pinDefaultMicrophone()
        readiness = await probe
    }

    /// Windows open and close while the panel is shut, so the list is asked for again
    /// every time it is shown. Without Screen Recording there is nothing to ask.
    func refreshCatalogue() async {
        guard phase == .idle else { return }

        canSeeScreen = Permissions.screenRecordingGranted()
        guard canSeeScreen else {
            catalogue = nil
            return
        }
        catalogue = try? await CaptureCatalogue.load()

        /// A window that has since closed is dropped rather than left selected, so
        /// Start cannot mean "record something that is gone". Matched on the target
        /// alone, because a window keeps its id while its title changes all call.
        guard let capture = configuration.capture else { return }
        if catalogue?.entries.contains(where: { $0.choice.target == capture.target }) != true {
            configuration.capture = nil
        }
    }

    func start() async {
        guard canStart else { return }
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
