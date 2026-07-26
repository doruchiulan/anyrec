import Foundation

/// Prepares a recorded track for an API that takes 25 MB and nothing larger.
///
/// Re-encoding to 16 kHz mono at 32 kbps costs nothing a speech model can hear
/// and buys about a hundred minutes per upload; splitting on the hour keeps
/// every part comfortably inside the limit however long the call ran.
public enum AudioChunks {
    public struct Chunk: Sendable, Equatable {
        public let url: URL
        /// Where this part begins in the original recording, so the timestamps
        /// coming back from the engine can be put back where they belong.
        public let start: TimeInterval
    }

    /// 14 MB at this bitrate, against a 25 MB ceiling.
    static let seconds = 3_600
    static let manifest = "parts.csv"

    public static func split(_ url: URL, into directory: URL) throws -> [Chunk] {
        guard let ffmpeg = Muxer.ffmpegPath() else { throw TranscriptionError.ffmpegNotFound }
        let list = directory.appendingPathComponent(manifest)

        let result = try Shell.run(
            ffmpeg,
            [
                "-nostdin", "-y", "-v", "error", "-i", url.path,
                "-ar", "16000", "-ac", "1", "-c:a", "libmp3lame", "-b:a", "32k",
                "-f", "segment", "-segment_time", String(seconds),
                "-segment_list", list.path, "-segment_list_type", "csv",
                directory.appendingPathComponent("part-%03d.mp3").path,
            ]
        )
        guard result.succeeded else {
            throw TranscriptionError.engineFailed(engine: "ffmpeg", log: result.combined)
        }

        let chunks = parse(try String(contentsOf: list, encoding: .utf8), in: directory)
        guard !chunks.isEmpty else {
            throw TranscriptionError.engineFailed(
                engine: "ffmpeg", log: "no parts were written for \(url.lastPathComponent)")
        }
        return chunks
    }

    /// ffmpeg writes one `file,start,end` row per part. The path it records is the
    /// one it was handed, so only the name is trusted.
    static func parse(_ csv: String, in directory: URL) -> [Chunk] {
        csv.split(separator: "\n").compactMap { line in
            let columns = line.split(separator: ",")
            guard columns.count >= 2, let start = TimeInterval(columns[1]) else { return nil }
            let name = URL(fileURLWithPath: String(columns[0])).lastPathComponent
            return Chunk(url: directory.appendingPathComponent(name), start: start)
        }
    }
}
