import AnyRecKit
import Foundation

/// What an automatic recording keeps: the call window's picture, or only its sound.
enum AutomaticRecordingMode: String, CaseIterable, Sendable {
    case window
    case audioOnly

    var video: Bool { self == .window }
}

/// When a call is recorded without anyone pressing Record, and when that recording stops.
///
/// Only Slack and Teams, and only once their call window is found the way the banner finds
/// it — through the app's own mute button. Every other app, and a call whose window cannot
/// be found, keeps the offer: recording an app's whole display, or a window guessed at,
/// is not something to do unasked. The window often appears a moment after the microphone
/// is taken, so it is looked for for as long as the call lasts.
///
/// Only a recording this started is stopped by it, and only once the call app has let go
/// of the microphone for `endGrace`: switching headsets or a call app restarting its audio
/// drops the microphone for a moment, and a call cut in two is worse than ten seconds of
/// silence at the end of one. A manual recording is never touched.
///
/// Pure state, fed the facts by `RecordingController`, so every decision is testable
/// without a call.
struct CallAutoRecording {
    /// How long the microphone has to stay released before a call counts as over.
    /// `CallWatch` reads every two seconds, so a release under that is never seen; ten
    /// seconds covers a Bluetooth headset reconnecting.
    static let endGrace: TimeInterval = 10

    /// What the controller knows at the moment of asking.
    struct Context: Equatable {
        /// Settings › General's switch.
        var enabled: Bool
        var mode: AutomaticRecordingMode
        /// Idle or showing a saved recording, setup complete, not quitting, and the mode
        /// records something (audio only with both audio tracks off would not).
        var canStart: Bool
    }

    enum CallStart: Equatable {
        /// Look for the call window, and start the moment it is found.
        case watch(CallApp)
        /// Today's behaviour: the banner or the notification.
        case offer(CallApp)
        /// The call that is being recorded automatically took the microphone back
        /// within the grace period: carry on.
        case resume
        /// A recording is running, or the app cannot start one: nothing to offer.
        case ignore
    }

    enum CallEnd: Equatable {
        case nothing
        /// The window was never found; stop looking.
        case stopWatching
        /// Ask `deadlinePassed` at this time.
        case stopAt(Date)
    }

    /// The call whose window is being looked for.
    private(set) var watching: CallApp?
    /// The call the running recording was started for automatically. Nil when nothing is
    /// recording or the recording was started by hand.
    private(set) var recording: CallApp?
    /// When the microphone was released, while that recording waits out the grace.
    private(set) var endedAt: Date?

    mutating func callStarted(_ app: CallApp, context: Context) -> CallStart {
        if let recording, recording == app, endedAt != nil {
            endedAt = nil
            return .resume
        }
        watching = nil
        guard context.canStart else { return .ignore }
        guard context.enabled, app.muteButton != nil else { return .offer(app) }
        watching = app
        return .watch(app)
    }

    /// The window was found and can be captured. Returns whether to keep its picture, or
    /// nil when it must not start after all: the setting was turned off, or a recording
    /// began meanwhile.
    mutating func windowFound(context: Context) -> Bool? {
        guard let app = watching else { return nil }
        watching = nil
        guard context.enabled, context.canStart else { return nil }
        recording = app
        endedAt = nil
        return context.mode.video
    }

    mutating func callEnded(at now: Date) -> CallEnd {
        if watching != nil {
            watching = nil
            return .stopWatching
        }
        guard recording != nil else { return .nothing }
        if endedAt == nil { endedAt = now }
        return .stopAt(endedAt!.addingTimeInterval(Self.endGrace))
    }

    /// True when the automatic recording should stop now: the call ended at least
    /// `endGrace` ago and did not come back.
    mutating func deadlinePassed(at now: Date) -> Bool {
        guard recording != nil, let endedAt, now.timeIntervalSince(endedAt) >= Self.endGrace else { return false }
        self.endedAt = nil
        return true
    }

    /// The switch was turned off. Returns the call that was being watched, to be offered
    /// instead. A recording already running carries on and still stops at the call's end.
    mutating func disabled() -> CallApp? {
        defer { watching = nil }
        return watching
    }

    /// The recording finished, however it finished — Stop, the window closing, the stop
    /// time — or never started.
    mutating func recordingEnded() {
        recording = nil
        endedAt = nil
    }
}
