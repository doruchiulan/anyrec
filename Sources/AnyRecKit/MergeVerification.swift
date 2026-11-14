import AVFoundation
import Foundation

/// What a media file holds, as far as a merge has to check it: each video stream's codec,
/// size and frame count, and each audio stream's length.
///
/// Read with AVFoundation rather than ffprobe. The ffmpeg anyrec fetches for itself is a
/// lone static binary with no ffprobe beside it, so ffprobe is not something every
/// machine that merges has; AVFoundation is. It is also what plays the file afterwards,
/// so a file it cannot read is one the library could not have played. Frames are counted
/// with a sample cursor, which walks the container's sample table and decodes nothing:
/// 16,663 frames of a 300 MB `screen.mov` in a few milliseconds.
public struct MediaFacts: Sendable, Equatable {
    public struct Video: Sendable, Equatable {
        public let codec: FourCharCode
        public let width: Int
        public let height: Int
        /// Nil when the container could not be walked; the duration is compared instead.
        public let frames: Int?
        public let duration: TimeInterval
        /// One frame's length, the tolerance when frames cannot be counted.
        public let frameDuration: TimeInterval

        public init(codec: FourCharCode, width: Int, height: Int, frames: Int?,
                    duration: TimeInterval, frameDuration: TimeInterval) {
            self.codec = codec
            self.width = width
            self.height = height
            self.frames = frames
            self.duration = duration
            self.frameDuration = frameDuration
        }

        public var isHEVC: Bool { codec == kCMVideoCodecType_HEVC || codec == FourCharCode(0x6865_7631) /* hev1 */ }
    }

    public let video: [Video]
    /// Each audio stream's length in seconds.
    public let audio: [TimeInterval]

    public init(video: [Video], audio: [TimeInterval]) {
        self.video = video
        self.audio = audio
    }

    public static func read(_ url: URL) async throws -> MediaFacts {
        let asset = AVURLAsset(url: url)
        var video: [Video] = []
        for track in try await asset.loadTracks(withMediaType: .video) {
            let (formats, range, rate, minimum, cursors) = try await track.load(
                .formatDescriptions, .timeRange, .nominalFrameRate, .minFrameDuration, .canProvideSampleCursors)
            guard let format = formats.first else { continue }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            video.append(Video(
                codec: CMFormatDescriptionGetMediaSubType(format),
                width: Int(dimensions.width), height: Int(dimensions.height),
                frames: cursors ? frames(of: track) : nil,
                duration: range.duration.seconds,
                frameDuration: rate > 0 ? 1 / Double(rate) : max(minimum.seconds.isFinite ? minimum.seconds : 0, 1.0 / 30)))
        }
        var audio: [TimeInterval] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            audio.append(try await track.load(.timeRange).duration.seconds)
        }
        return MediaFacts(video: video, audio: audio)
    }

    /// Stepped a block at a time: one step of `Int64.max` takes no steps at all.
    private static func frames(of track: AVAssetTrack) -> Int? {
        guard let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return nil }
        var count = 1
        while true {
            let taken = cursor.stepInDecodeOrder(byCount: 4096)
            guard taken > 0 else { break }
            count += Int(taken)
        }
        return count
    }
}

/// Whether a merge's result can stand in for what it was made from. Checked before the
/// result is moved into place and long before `screen.mov` is deleted, so a merge that
/// lost frames or the audio leaves the folder as it was.
public enum MergeVerification {
    /// The mix runs to the longest track, and AAC pads its ends by a frame or two of
    /// silence: on a 10-minute call the mix came out 44 ms shorter than the longer track.
    public static let audioTolerance: TimeInterval = 0.5

    /// Nil when the result holds the reference's video exactly and the mixed audio;
    /// otherwise what is wrong, in words for the log.
    public static func problem(
        with result: MediaFacts, video reference: MediaFacts.Video?, audio expected: TimeInterval?
    ) -> String? {
        if let reference {
            guard result.video.count == 1, let video = result.video.first else {
                return "the merged file has \(result.video.count) video streams, not one"
            }
            guard video.codec == reference.codec else {
                return "the merged video is \(fourCC(video.codec)), not \(fourCC(reference.codec))"
            }
            guard video.width == reference.width, video.height == reference.height else {
                return "the merged video is \(video.width)×\(video.height), not \(reference.width)×\(reference.height)"
            }
            if let frames = video.frames, let original = reference.frames {
                guard frames == original else {
                    return "the merged video has \(frames) frames, not \(original)"
                }
            } else if abs(video.duration - reference.duration) > reference.frameDuration {
                return String(format: "the merged video runs %.2f s, not %.2f s", video.duration, reference.duration)
            }
        } else if !result.video.isEmpty {
            return "the merged file has a video stream where none was expected"
        }

        if let expected {
            guard result.audio.count == 1, let audio = result.audio.first else {
                return "the merged file has \(result.audio.count) audio streams, not one"
            }
            guard abs(audio - expected) <= audioTolerance else {
                return String(format: "the merged audio runs %.2f s, not %.2f s", audio, expected)
            }
        } else if !result.audio.isEmpty {
            return "the merged file has audio where no track was recorded"
        }
        return nil
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = withUnsafeBytes(of: code.bigEndian, Array.init)
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }
}
