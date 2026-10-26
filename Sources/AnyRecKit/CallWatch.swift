import Foundation

/// A call starting, read the same way mute is: a call app taking the microphone.
///
/// Nothing is listened to. Core Audio's process list says which apps are running
/// input, and the first known call app to appear there is a call beginning — Teams
/// holds the microphone from the moment you join, muted or not, and so do Slack,
/// Zoom, FaceTime and a browser in a meeting. An app testing its microphone in its
/// settings looks the same, which is why what follows is an offer and not an action.
public final class CallWatch {
    public enum Event: Sendable, Equatable {
        case started(CallApp)
        case ended
    }

    /// A call is joined by a hand; every two seconds is soon enough.
    static let interval: TimeInterval = 2

    private let apps: [CallApp]
    private let queue = DispatchQueue(label: "ro.qlan.anyrec.call-watch")
    private var timer: DispatchSourceTimer?
    private var current: CallApp?

    public init(apps: [CallApp] = CallApps.known) {
        self.apps = apps
    }

    deinit { timer?.cancel() }

    /// `handler` is called on the watch's own queue, once per change.
    public func start(_ handler: @escaping @Sendable (Event) -> Void) {
        queue.sync {
            timer?.cancel()
            current = nil
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Self.interval)
            timer.setEventHandler { [weak self] in self?.scan(handler) }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            current = nil
        }
    }

    private func scan(_ handler: (Event) -> Void) {
        let found = Self.app(holding: AudioProcesses.snapshot(), among: apps)
        guard found != current else { return }
        if current != nil { handler(.ended) }
        if let found { handler(.started(found)) }
        current = found
    }

    /// The first known app running microphone input. A browser's audio runs in a
    /// helper with the browser's id and a suffix, so an app also covers everything
    /// under it.
    public static func app(holding processes: [AudioProcess], among apps: [CallApp]) -> CallApp? {
        apps.first { app in
            processes.contains { process in
                process.runningInput
                    && (process.bundleID == app.bundleID
                        || process.bundleID.hasPrefix(app.bundleID + "."))
            }
        }
    }
}
