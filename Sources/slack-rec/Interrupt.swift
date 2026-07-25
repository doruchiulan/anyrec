import Dispatch
import Foundation

/// Suspends until Ctrl-C / SIGTERM / the terminal closing, or until an optional
/// deadline passes — whichever lands first. The default handlers are disabled so
/// the writers get a chance to finalise their files instead of the process dying
/// mid-frame, leaving a `.mov` with no `moov` atom that nothing can open.
final class Interrupt: @unchecked Sendable {
    private static let watched = [SIGINT, SIGTERM, SIGHUP]

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false
    private var fired = false
    private var sources: [DispatchSourceSignal] = []
    private var timer: DispatchSourceTimer?

    static func wait(timeout: TimeInterval?) async {
        await Interrupt().suspend(timeout: timeout)
    }

    /// Watches without suspending, so a redraw loop can poll it between keypresses.
    /// The caller must hold on to the result: releasing it cancels the watch.
    static func watching() -> Interrupt {
        let interrupt = Interrupt()
        interrupt.install(timeout: nil)
        return interrupt
    }

    var isTriggered: Bool { lock.withLock { fired } }

    deinit {
        sources.forEach { $0.cancel() }
        timer?.cancel()
        Self.watched.forEach { signal($0, SIG_DFL) }
    }

    private func suspend(timeout: TimeInterval?) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            install(timeout: timeout)
        }
    }

    private func install(timeout: TimeInterval?) {
        for number in Self.watched {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.fire() }
            source.resume()
            sources.append(source)
        }

        guard let timeout else { return }
        let deadline = DispatchSource.makeTimerSource(queue: .global())
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler { [weak self] in self?.fire() }
        deadline.resume()
        timer = deadline
    }

    private func fire() {
        lock.lock()
        defer { lock.unlock() }
        fired = true
        guard !resumed, let continuation else { return }
        resumed = true
        self.continuation = nil
        continuation.resume()
    }
}
