import FluidAudio
import Foundation

/// FluidAudio's network switch, `ModelHub.offlineMode`, is one flag for the whole process.
/// Each download used to switch it on and back off around itself, so two at once broke
/// each other. The welcome window offers the speaker models (22 MB) and Parakeet (480 MB)
/// side by side, and when the speaker models finished first they switched the network off
/// under Parakeet: its remaining files failed, and it read as never downloaded.
///
/// So downloads are counted. The network stays on while any download is running, and only
/// the last one to finish turns it off again.
enum ModelNetwork {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var downloads = 0

    /// Runs `body` with FluidAudio allowed on the network.
    static func downloading<T>(_ body: () async throws -> T) async throws -> T {
        lock.withLock {
            downloads += 1
            ModelHub.offlineMode = false
        }
        defer {
            lock.withLock {
                downloads -= 1
                if downloads == 0 { ModelHub.offlineMode = true }
            }
        }
        return try await body()
    }

    /// Transcription's side: turn the network off before loading a model. Skipped while a
    /// download is running, so loading does not stop that download. The loaders read from
    /// folders already checked as complete (`ParakeetSetup.isReady`,
    /// `SpeakerSetup.isReady`), so they have nothing to fetch either way.
    static func offline() {
        lock.withLock {
            if downloads == 0 { ModelHub.offlineMode = true }
        }
    }
}
