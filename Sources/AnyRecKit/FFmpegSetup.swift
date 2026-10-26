import Foundation

/// ffmpeg without Homebrew: a static build fetched once into
/// `~/Library/Application Support/anyrec/bin`, where `Muxer.ffmpegPath` looks after the
/// places a package manager would have put one. The build is ffmpeg-static's, which
/// redistributes the macOS builds from osxexperts.net — GPL, with every filter the merge
/// and the mix use (ebur128, sidechaincompress, amix) and both encoders (aac, libmp3lame).
/// Pinned by version and checksum, one per architecture.
public enum FFmpegSetup {
    public static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/anyrec/bin")
    public static var path: URL { directory.appendingPathComponent("ffmpeg") }

    static let release = "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/"

    /// The build for this machine. Universal is not on offer, so the app's own slice
    /// decides, which is the slice the process is.
    public static var asset: AssetDownload.Asset {
        #if arch(arm64)
            AssetDownload.Asset(
                name: "ffmpeg", url: URL(string: release + "ffmpeg-darwin-arm64")!,
                sha256: "a90e3db6a3fd35f6074b013f948b1aa45b31c6375489d39e572bea3f18336584",
                bytes: 45_568_216)
        #else
            AssetDownload.Asset(
                name: "ffmpeg", url: URL(string: release + "ffmpeg-darwin-x64")!,
                sha256: "ebdddc936f61e14049a2d4b549a412b8a40deeff6540e58a9f2a2da9e6b18894",
                bytes: 78_862_176)
        #endif
    }

    public static var downloadSize: String { AssetDownload.describe(asset.bytes) }

    /// Whether there is an ffmpeg to run, wherever it came from.
    public static var isReady: Bool { Muxer.ffmpegPath() != nil }

    public static func fetch(progress: @escaping @Sendable (String) -> Void) async throws {
        let total = downloadSize
        let file = try await AssetDownload.fetch(asset, into: directory) {
            progress("\(AssetDownload.describe($0)) of \(total)")
        }
        /// A tool, not a model: it has to be executable, and it must not carry the
        /// quarantine a download picks up, which would have Gatekeeper refuse to run it.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        removexattr(file.path, "com.apple.quarantine", 0)
    }
}
