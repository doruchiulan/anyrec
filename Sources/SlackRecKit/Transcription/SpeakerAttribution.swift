import Foundation

/// Puts a name to each line by measuring, not by guessing.
///
/// The mix is what gets transcribed, but the two tracks that went into it are still
/// on disk — so for any span of the call it can be asked which side was louder. That
/// answer is exact, and it survives the microphone picking up the speakers: the far
/// end coming back through a room is always quieter than the copy that arrived down
/// the wire, so an echoed line still lands on the call's side of the ledger.
public enum SpeakerAttribution {
    /// How much louder one track has to run before the line is called for it. Below
    /// this the two are too close to separate, and the call is the safer answer:
    /// putting the far end's words in your mouth is the worse mistake.
    static let margin = 1.5

    public static func label(
        _ utterances: [Utterance], microphone: AudioEnvelope, systemAudio: AudioEnvelope
    ) -> [Utterance] {
        guard !microphone.isEmpty, !systemAudio.isEmpty else { return utterances }
        let voices = Set(utterances.map(\.speaker)).filter { $0 != .me && $0 != .others }
        guard voices.isEmpty else {
            return relabel(utterances, mine: mine(utterances, microphone, systemAudio))
        }
        return utterances.map {
            var line = $0
            line.speaker = spoke(from: $0, microphone, systemAudio) ? .me : .others
            return line
        }
    }

    private static func spoke(
        from utterance: Utterance, _ microphone: AudioEnvelope, _ systemAudio: AudioEnvelope
    ) -> Bool {
        let mine = microphone.level(from: utterance.start, to: utterance.end)
        let theirs = systemAudio.level(from: utterance.start, to: utterance.end)
        return ratio(mine, theirs) >= margin
    }

    /// Diarisation says how many voices there were, not which one is holding the
    /// microphone. Every line a voice spoke is weighed at once, so one leaked word
    /// cannot claim a whole speaker — and only the strongest claim is honoured,
    /// because there is exactly one of you.
    static func mine(
        _ utterances: [Utterance], _ microphone: AudioEnvelope, _ systemAudio: AudioEnvelope
    ) -> Speaker? {
        let scored = Dictionary(grouping: utterances, by: \.speaker).map { speaker, lines in
            (speaker, dominance(lines, microphone, systemAudio))
        }
        return scored.filter { $0.1 >= margin }.max { $0.1 < $1.1 }?.0
    }

    private static func dominance(
        _ lines: [Utterance], _ microphone: AudioEnvelope, _ systemAudio: AudioEnvelope
    ) -> Double {
        let level = { (envelope: AudioEnvelope) in
            lines.map { envelope.level(from: $0.start, to: $0.end) * ($0.end - $0.start) }
                .reduce(0, +)
        }
        return ratio(level(microphone), level(systemAudio))
    }

    private static func relabel(_ utterances: [Utterance], mine: Speaker?) -> [Utterance] {
        guard let mine else { return utterances }
        return utterances.map {
            guard $0.speaker == mine else { return $0 }
            var line = $0
            line.speaker = .me
            return line
        }
    }

    private static func ratio(_ mine: Double, _ theirs: Double) -> Double {
        guard theirs > 0 else { return mine > 0 ? .infinity : 0 }
        return mine / theirs
    }
}
