import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A still from the recording, for the library's list. Taken a tenth of the way in —
/// the first frame of a call is usually the lobby — and kept beside the tracks as
/// `thumbnail.jpg`, a derived file like `waveform.json` that is simply made again if
/// it is deleted.
public enum Thumbnail {
    public static let fileName = "thumbnail.jpg"

    /// The still's file, made the first time it is asked for. Nil when there is no video
    /// or no frame could be read.
    public static func of(_ entry: LibraryEntry) async -> URL? {
        let cache = entry.directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: cache.path) { return cache }
        guard let video = entry.video else { return nil }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let at = CMTime(seconds: max(0, entry.duration * 0.1), preferredTimescale: 600)
        guard let image = try? await generator.image(at: at).image,
            let destination = CGImageDestinationCreateWithURL(
                cache as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? cache : nil
    }
}
