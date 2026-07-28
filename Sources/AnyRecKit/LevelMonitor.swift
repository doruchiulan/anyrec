import Foundation

/// Live audio levels: written on the capture queue, read by whatever is drawing them.
public final class LevelMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [AudioTrack: AudioLevel] = [:]
    private var stamps: [AudioTrack: UInt64] = [:]
    private var peaks: [AudioTrack: Float] = [:]

    public init() {}

    public func record(_ level: AudioLevel, for track: AudioTrack) {
        lock.withLock {
            latest[track] = level
            stamps[track] = DispatchTime.now().uptimeNanoseconds
            peaks[track] = max(peaks[track] ?? AudioLevel.floor, level.peak)
        }
    }

    /// Falls back to silence once buffers stop arriving, so a stalled meter reads empty
    /// rather than freezing at its last value.
    public func level(for track: AudioTrack, staleAfter: TimeInterval = 0.4) -> AudioLevel {
        lock.withLock {
            guard let level = latest[track], let stamp = stamps[track] else { return .silence }
            let age = Double(DispatchTime.now().uptimeNanoseconds &- stamp) / 1_000_000_000
            return age > staleAfter ? .silence : level
        }
    }

    /// The loudest peak seen for the whole run.
    public func sessionPeak(for track: AudioTrack) -> Float {
        lock.withLock { peaks[track] ?? AudioLevel.floor }
    }

    public func sawAnySignal(on track: AudioTrack) -> Bool {
        sessionPeak(for: track) > AudioLevel.floor
    }
}
