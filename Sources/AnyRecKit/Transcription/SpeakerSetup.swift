import FluidAudio
import Foundation

/// What stands between a fresh machine and the far end being told apart: about 22 MB
/// of speaker models, fetched once into the models folder. Optional throughout, like
/// everything else transcription needs.
public enum SpeakerSetup {
    /// FluidAudio lays its files out under `<models>/speaker-diarization/`, beside the
    /// whisper models.
    public static let directory = WhisperTranscriber.modelDirectory
    static var folder: URL { directory.appendingPathComponent("speaker-diarization") }

    /// Segmentation, filter bank, embedding and PLDA models, plus their parameters.
    public static let bytes: Int64 = 22_000_000
    public static var downloadSize: String { AssetDownload.describe(bytes) }

    /// FluidAudio narrates every stage at debug level, onto the console in a debug
    /// build. Nothing below a warning is anyrec's business, or the user's.
    static func quiet() {
        AppLogger.minimumLevel = .warning
    }

    public static var isReady: Bool {
        ModelNames.OfflineDiarizer.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// The one place FluidAudio is allowed on the network. It fetches a pinned
    /// revision over HTTPS and checks each file's size against the published one.
    /// There is no checksum in its code to check against — the models are several
    /// files each, which is why they do not come through `AssetDownload` — so this
    /// is the documented exception to the rule that a download is verified.
    public static func fetch(progress: @escaping @Sendable (String) -> Void) async throws {
        quiet()
        ModelHub.offlineMode = false
        defer { ModelHub.offlineMode = true }
        _ = try await OfflineDiarizerModels.load(from: directory) { report in
            progress("\(Int((report.fractionCompleted * 100).rounded()))%")
        }
    }
}
