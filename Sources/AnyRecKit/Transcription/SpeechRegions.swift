import Foundation

/// Where the voice actually is in a track.
///
/// An engine handed a long stretch of room tone does not return nothing: whisper
/// invents a sentence and tiles copies of it across the silence on a regular grid.
/// Those fake lines carry real timestamps, which is what puts a transcript's turns
/// in an order the call never had. Uploading only the speech removes the material
/// it hallucinates from.
public enum SpeechRegions {
    /// Speech has to clear the noise floor by this much — 12 dB is well above a fan
    /// and well below anyone talking.
    static let overFloor = 4.0
    /// The threshold is never allowed above this share of the loudest frame, so a
    /// track that is nothing but speech cannot raise its own floor out of reach.
    static let ceilingShare = 0.2
    /// Pauses shorter than this belong to the sentence around them.
    static let gap: TimeInterval = 1.0
    /// Kept either side, because a word starts quieter than its middle.
    static let padding: TimeInterval = 0.3
    /// Below this there is no room for a word.
    static let minimum: TimeInterval = 0.4

    public static func detect(in envelope: AudioEnvelope) -> [Range<TimeInterval>] {
        guard envelope.peak > 0 else { return [] }
        let threshold = min(envelope.noiseFloor * overFloor, envelope.peak * ceilingShare)
        let loud = envelope.frames.indices.filter { envelope.frames[$0] > threshold }
        return group(loud)
            .filter { AudioEnvelope.time(of: $0.count) >= minimum }
            .map { pad($0, within: envelope.duration) }
    }

    /// Runs of loud frames, broken wherever the quiet between them outlasts `gap`.
    private static func group(_ loud: [Int]) -> [Range<Int>] {
        guard let first = loud.first else { return [] }
        var runs: [Range<Int>] = []
        var start = first
        var previous = first

        for index in loud.dropFirst() {
            if AudioEnvelope.time(of: index - previous) > gap {
                runs.append(start..<(previous + 1))
                start = index
            }
            previous = index
        }
        runs.append(start..<(previous + 1))
        return runs
    }

    private static func pad(_ run: Range<Int>, within duration: TimeInterval) -> Range<TimeInterval>
    {
        let start = max(0, AudioEnvelope.time(of: run.lowerBound) - padding)
        let end = min(duration, AudioEnvelope.time(of: run.upperBound) + padding)
        return start..<max(start, end)
    }
}
