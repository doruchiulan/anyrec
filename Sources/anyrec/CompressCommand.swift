import ArgumentParser
import Foundation
import AnyRecKit

/// `anyrec compress`: the app's background compression, run on one recording now.
struct Compress: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compress",
        abstract: "Re-encode a recording's merged video about fifteen times smaller.",
        discussion: """
        Re-encodes the merged file's video with x265 at the same resolution, checks every \
        frame is there and the audio is unchanged, then replaces the file. Only for a \
        merged file that holds the only copy of the picture, once. The audio tracks are \
        never touched. Ctrl-C leaves the folder as it was.
        """
    )

    @Argument(help: "A recording folder. Defaults to the newest recording.")
    var recording: String?

    @Option(name: .shortAndLong, help: "Where recordings are, when no folder is given.")
    var output = Defaults.outputRoot

    func run() async throws {
        guard let ffmpeg = Muxer.ffmpegPath() else { throw ValidationError(MuxError.ffmpegNotFound.description) }
        let chosen: URL
        if let recording {
            chosen = URL(fileURLWithPath: recording.expandingTilde)
        } else if let newest = Recordings.newest(in: URL(fileURLWithPath: output.expandingTilde)) {
            chosen = newest
        } else {
            throw ValidationError("No recording found in \(output).")
        }
        let folder = Recordings.prepared(chosen)
        guard let merged = Compression.candidate(in: folder) else {
            throw ValidationError("\(folder.lastPathComponent) has nothing to compress: no merged video, "
                + "screen.mov still beside it, audio only, or already compressed.")
        }
        print("Compressing \(merged.lastPathComponent)…")
        let started = Date()
        switch try await Compression.compress(folder, using: ffmpeg) {
        case .compressed(let before, let after):
            print("\(size(before)) → \(size(after)) in \(Int(Date().timeIntervalSince(started))) s.")
        case .notWorthwhile(let before, let after):
            print("Kept as it was: \(size(before)) would only have become \(size(after)).")
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
