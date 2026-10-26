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

struct ProposedSpeakerChange: Decodable {
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
    @discardableResult
    public static func apply(_ correction: SpeakerCorrection, to file: URL) throws -> [URL] {
        let directory = file.deletingLastPathComponent()
        guard TranscriptStore.activeTranscript(in: directory) == file,
              let transcript = Transcript.read(file), var review = TranscriptReview.read(in: directory),
              review.speakerChanges.contains(correction), transcript.utterances.indices.contains(correction.line),
              transcript.utterances[correction.line].speaker == correction.from else {
            throw TranscriptionError.engineFailed(engine: "review", log: "The transcript changed. Reopen this recording to review its current suggestions.")
        }
        var lines = transcript.utterances
        lines[correction.line].speaker = correction.to
        review.speakerChanges.removeAll { $0.line == correction.line }
        let updated = TranscriptReview(provider: review.provider, sources: review.sources,
            suggestions: review.suggestions.filter { $0.line != correction.line }, failures: review.failures,
            speakerChanges: review.speakerChanges)
        let corrected = Transcript(utterances: lines, language: transcript.language, engine: transcript.engine,
                                   notes: transcript.notes)
        return try TranscriptStore.publish(corrected, voices: RecordingVoices.read(in: directory),
                                           in: directory, review: updated)
    }
}
