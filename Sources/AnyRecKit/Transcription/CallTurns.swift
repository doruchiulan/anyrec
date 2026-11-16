import Foundation

/// Where the call started or stopped talking, as word indices, so lines can be cut at
/// turns that punctuation and pauses miss.
///
/// Parakeet ends a line only at a sentence end or a pause. Turns often flip with neither:
/// on a real call, "Audio only." (the owner), then "A, bine, îi dau eu doar când vorbesc cu
/// Claudiu, de fapt" (the far end), then "Păi nu…" (the owner again) came back as one line,
/// and the whole of it went to Me because the microphone was louder over it. The call
/// track says exactly when the far end spoke (−95 dB, then −26 dB at 95.0 s, back to
/// −97 dB at 98.3 s), so each word is marked by whether the call was talking under it, and
/// a line starts wherever that changes. Attribution then weighs each part on its own.
enum CallTurns {
    /// A change has to hold for this long before it counts. Shorter flips, such as an
    /// "mhm" from the other side or a breath, would only fragment a sentence.
    static let minimum: TimeInterval = 0.6

    /// Word indices where a line must start. `systemAudio` is the call track on the
    /// microphone's timeline (aligned), as attribution reads it.
    static func cuts(in words: [Speech.Word], systemAudio: AudioEnvelope) -> Set<Int> {
        guard words.count > 1, systemAudio.peak > 0 else { return [] }
        let threshold = SpeechRegions.threshold(for: systemAudio)
        let talking = words.map { systemAudio.level(from: $0.start, to: max($0.end, $0.start + 0.02)) > threshold }

        /// Runs of words with the call in the same state, the short ones folded into the
        /// run before them so only a held change makes a cut.
        var runs: [(start: Int, talking: Bool)] = []
        var index = 0
        while index < words.count {
            var end = index
            while end + 1 < words.count, talking[end + 1] == talking[index] { end += 1 }
            let held = words[end].end - words[index].start >= minimum
            let continues = runs.last.map { $0.talking == talking[index] || !held } ?? false
            if !continues { runs.append((index, talking[index])) }
            index = end + 1
        }
        return Set(runs.dropFirst().map(\.start))
    }
}
