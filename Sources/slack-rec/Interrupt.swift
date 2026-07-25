import Dispatch
import Foundation

/// Suspends until Ctrl-C / SIGTERM, or until an optional deadline passes —
/// whichever lands first. The default SIGINT handler is disabled so the writers
/// get a chance to finalise their files instead of the process dying mid-frame.
final class Interrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false
    private var sources: [DispatchSourceSignal] = []
    private var timer: DispatchSourceTimer?

    static func wait(timeout: TimeInterval?) async {
        await Interrupt().suspend(timeout: timeout)
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
        for number in [SIGINT, SIGTERM] {
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
        guard !resumed, let continuation else { return }
        resumed = true
        self.continuation = nil
        continuation.resume()
    }
}
