import Foundation

public struct SpeakerCorrection: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { line }
    public let line: Int
    public let from: Speaker
    public let to: Speaker
    public let reason: String
    public let quote: String
    public let evidenceLine: Int
}

struct ProposedSpeakerChange: Decodable, Sendable {
    let line: Int
    let target: String
    let reason: String
    let quote: String
    let evidenceLine: Int

    func validated(in transcript: Transcript, range: Range<Int>) -> SpeakerCorrection? {
        guard range.contains(line), transcript.utterances.indices.contains(evidenceLine), !reason.isEmpty, reason.count <= 1_000,
              quote.count >= 3, transcript.utterances[evidenceLine].text.contains(quote),
              let speaker = transcript.utterances.map(\.speaker).first(where: { $0.label == target }),
              speaker != transcript.utterances[line].speaker else { return nil }
        return SpeakerCorrection(line: line, from: transcript.utterances[line].speaker, to: speaker,
                                 reason: reason, quote: quote, evidenceLine: evidenceLine)
    }
}

public enum TranscriptSpeakerReview {
    /// Accepts one proposed speaker correction: that line's speaker changes in the speakers
    /// layer, and nothing else does — the wording and the summary stay, and the summary
    /// says it is stale because who said what changed.
    @discardableResult
    public static func apply(_ correction: SpeakerCorrection, in directory: URL) throws -> [URL] {
        try TranscriptStore.updateSpeakers(in: directory) { layer, current in
            guard current.pendingSpeakerChanges.contains(correction) else {
                throw TranscriptionError.engineFailed(engine: "review", log: "The transcript changed. Reopen this recording to review its current suggestions.")
            }
            var speakers = layer.speakers ?? current.transcript.utterances.map(\.speaker)
            speakers[correction.line] = correction.to
            layer.speakers = speakers
            layer.decided.append(correction.line)
        }
    }

    /// Leaves a proposed correction as it is and stops offering it.
    @discardableResult
    public static func dismiss(_ correction: SpeakerCorrection, in directory: URL) throws -> [URL] {
        try TranscriptStore.updateSpeakers(in: directory) { layer, _ in layer.decided.append(correction.line) }
    }
}
