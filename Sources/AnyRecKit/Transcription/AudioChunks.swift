import Foundation

/// Cuts a track into the pieces that get uploaded, one per stretch of speech.
///
/// Re-encoding to 16 kHz mono at 32 kbps costs nothing a speech model can hear and
/// buys about a hundred minutes per upload; cutting on silence keeps the long quiet
/// stretches — the ones an engine fills with invented sentences — off the wire
/// entirely, and each piece carries the offset that puts its timestamps back.
public enum AudioChunks {
    public struct Chunk: Sendable, Equatable {
        public let url: URL
        /// Where this piece begins in the original recording, so the timestamps
        /// coming back from the engine can be put back where they belong.
        public let start: TimeInterval
    }

    /// 14 MB at this bitrate, against a 25 MB ceiling.
    static let seconds: TimeInterval = 3_600

    public static func split(
        _ url: URL, speech regions: [Range<TimeInterval>], into directory: URL
    ) throws -> [Chunk] {
        guard let ffmpeg = Muxer.ffmpegPath() else { throw TranscriptionError.ffmpegNotFound }
        let parts = capped(regions)
        guard !parts.isEmpty else { return [] }

        let chunks = parts.enumerated().map { index, part in
            Chunk(url: directory.appendingPathComponent(name(index)), start: part.lowerBound)
        }
        let arguments = ["-nostdin", "-y", "-v", "error", "-i", url.path]
            + zip(parts, chunks).flatMap(encode)

        let result = try Shell.run(ffmpeg, arguments)
        guard result.succeeded else {
            throw TranscriptionError.engineFailed(engine: "ffmpeg", log: result.combined)
        }
        return chunks
    }

    /// `-ss` and `-t` after the input are output options: ffmpeg decodes to the mark
    /// rather than seeking near it, which is what keeps every offset exact.
    private static func encode(_ part: Range<TimeInterval>, _ chunk: Chunk) -> [String] {
        [
            "-ss", String(part.lowerBound), "-t", String(part.upperBound - part.lowerBound),
            "-ar", "16000", "-ac", "1", "-c:a", "libmp3lame", "-b:a", "32k", chunk.url.path,
        ]
    }

    static func name(_ index: Int) -> String { String(format: "part-%03d.mp3", index) }

    /// A single region can outrun the upload limit on its own — a lecture, or a call
    /// nobody paused during — so anything past the cap is split again on time.
    static func capped(_ regions: [Range<TimeInterval>]) -> [Range<TimeInterval>] {
        regions.flatMap { region in
            stride(from: region.lowerBound, to: region.upperBound, by: seconds).map {
                $0..<min($0 + seconds, region.upperBound)
            }
        }
    }
}
