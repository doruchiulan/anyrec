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

    /// Diarisation says how many voices there were, not which of them is holding the
    /// microphone — and it fuses two people into one letter when they take turns
    /// quickly. So every line is weighed on its own: yours are the ones the microphone
    /// heard louder, whatever letter they arrived under.
    public static func label(
        _ utterances: [Utterance], microphone: AudioEnvelope, systemAudio: AudioEnvelope
    ) -> [Utterance] {
        guard !microphone.isEmpty, !systemAudio.isEmpty else { return utterances }
        return renumber(utterances.flatMap { claim($0, microphone, systemAudio) })
    }

    /// One segment can still hold two people, because the model gives a whole span a
    /// single letter when a reply lands inside it. The seam is a sentence end, so the
    /// line is cut there and each part measured alone — and stays cut only if the
    /// parts disagree about who was talking.
    private static func claim(
        _ utterance: Utterance, _ microphone: AudioEnvelope, _ systemAudio: AudioEnvelope
    ) -> [Utterance] {
        let parts = sentences(of: utterance).map { part -> Utterance in
            guard spoke(from: part, microphone, systemAudio) else { return part }
            var line = part
            line.speaker = .me
            return line
        }
        guard Set(parts.map(\.speaker)).count > 1 else {
            var line = utterance
            line.speaker = parts[0].speaker
            return [line]
        }
        return parts
    }

    /// Time is shared out by length. A word-level clock would place the cut better,
    /// but no engine that diarises returns one, and the parts only have to be right
    /// enough that each lands on its own side of the seam.
    private static func sentences(of utterance: Utterance) -> [Utterance] {
        let parts = sentences(in: utterance.text)
        guard parts.count > 1 else { return [utterance] }
        let letters = Double(parts.reduce(0) { $0 + $1.count })
        var start = utterance.start
        return parts.map { text in
            let span = (utterance.end - utterance.start) * Double(text.count) / letters
            defer { start += span }
            return Utterance(
                start: start, end: start + span, text: text, speaker: utterance.speaker)
        }
    }

    /// A terminator only ends a sentence when a space follows it, which is what keeps
    /// "3.5" and an ellipsis in one piece.
    private static func sentences(in text: String) -> [String] {
        let characters = Array(text)
        var parts: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard ".!?".contains(character),
                index + 1 == characters.count || characters[index + 1] == " "
            else { continue }
            parts.append(current)
            current = ""
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func spoke(
        from utterance: Utterance, _ microphone: AudioEnvelope, _ systemAudio: AudioEnvelope
    ) -> Bool {
        let mine = microphone.level(from: utterance.start, to: utterance.end)
        let theirs = systemAudio.level(from: utterance.start, to: utterance.end)
        return ratio(mine, theirs) >= margin
    }

    /// Taking your lines out of a diarised set leaves a gap in its letters, or opens
    /// the call on "Speaker B". What is left is lettered again, in the order it is
    /// first heard.
    private static func renumber(_ utterances: [Utterance]) -> [Utterance] {
        var letters: [String: String] = [:]
        for line in utterances.sorted(by: { $0.start < $1.start }) {
            guard case .voice(let heard) = line.speaker, letters[heard] == nil else { continue }
            letters[heard] = letter(letters.count)
        }
        return utterances.map {
            guard case .voice(let heard) = $0.speaker, let renamed = letters[heard]
            else { return $0 }
            var line = $0
            line.speaker = .voice(renamed)
            return line
        }
    }

    static func letter(_ index: Int) -> String {
        index < 26 ? String(UnicodeScalar(UInt8(65 + index))) : "\(index + 1)"
    }

    private static func ratio(_ mine: Double, _ theirs: Double) -> Double {
        guard theirs > 0 else { return mine > 0 ? .infinity : 0 }
        return mine / theirs
    }
}
