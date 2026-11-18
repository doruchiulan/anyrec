import CryptoKit
import Foundation

/// The far end's voices, kept beside the tracks as `diarization.json` so a transcript
/// regenerated with another engine costs only that engine. Keyed by a SHA-256 of the
/// exact audio the diarizer heard: a different mix — new gains, a changed mute record,
/// a re-recorded track — hashes differently and is diarized again. Never reused for
/// audio it was not computed from.
enum DiarizationCache {
    struct Stored: Codable {
        static let version = 1
        var version = Stored.version
        let audio: String
        let segments: [VoiceSegment]
        let prints: [String: Voiceprint]
    }

    static let fileName = "diarization.json"

    typealias Heard = (segments: [VoiceSegment], prints: [String: Voiceprint])

    static func heard(
        _ audio: URL, in directory: URL?, diarize: (URL) async throws -> Heard
    ) async throws -> Heard {
        guard let directory, let digest = digest(of: audio) else { return try await diarize(audio) }
        let layout = RecordingLayout(directory: directory)
        if let data = try? Data(contentsOf: layout.readURL(fileName)), let stored = try? JSONDecoder().decode(Stored.self, from: data),
           stored.version == Stored.version, stored.audio == digest {
            return (stored.segments, stored.prints)
        }
        let heard = try await diarize(audio)
        if let data = try? JSONEncoder().encode(Stored(audio: digest, segments: heard.segments, prints: heard.prints)) {
            try? data.write(to: layout.writeURL(fileName), options: .atomic)
        }
        return heard
    }

    static func digest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
