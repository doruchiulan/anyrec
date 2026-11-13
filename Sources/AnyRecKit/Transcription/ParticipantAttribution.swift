import Foundation

public struct SpeakerIdentityEvidence: Codable, Equatable, Sendable {
    public struct Resolution: Codable, Equatable, Sendable {
        public let name: String
        public let reason: String
        public let provider: SummaryProvider
    }

    public let callNames: [String]
    public let voiceprintName: String?
    public let conflict: Bool
    public var resolution: Resolution? = nil
}

enum ParticipantAttribution {
    static func apply(
        _ voices: RecordingVoices?, lines: [Utterance], evidence: CallParticipants?
    ) -> RecordingVoices? {
        guard var result = voices, let evidence else { return voices }
        let spans = evidence.spans
        for index in result.voices.indices {
            let voice = result.voices[index]
            let candidates = candidates(for: voice.letter, lines: lines, spans: spans)
            guard !candidates.isEmpty else { continue }
            let conflict = candidates.count > 1 || voice.name.map { normalized($0) != normalized(candidates[0]) } == true
            result.voices[index].identityEvidence = SpeakerIdentityEvidence(
                callNames: candidates, voiceprintName: voice.name, conflict: conflict)
            result.voices[index].name = conflict ? nil : (voice.name ?? candidates[0])
        }
        rejectDuplicateNames(&result)
        return result
    }

    private static func candidates(
        for letter: String, lines: [Utterance], spans: [CallParticipants.Span]
    ) -> [String] {
        let clean = lines.filter { line in
            line.speaker == .voice(letter) && line.start.isFinite && line.end.isFinite && line.start >= 0
                && line.end - line.start >= 1.5 && !lines.contains {
                    $0.speaker != line.speaker && $0.start < line.end && $0.end > line.start
                }
        }
        var seconds: [String: Double] = [:]
        var turns: [String: Int] = [:]
        var duration = 0.0
        var previousEnd = 0.0
        for line in clean.sorted(by: { $0.start < $1.start }) {
            let start = max(line.start + 0.35, previousEnd), end = line.end - 0.35
            guard end > start else { continue }
            previousEnd = end
            duration += end - start
            var heard: [String: Double] = [:]
            for span in spans {
                heard[span.name, default: 0] += max(0, min(end, span.end) - max(start, span.start))
            }
            for (name, amount) in heard where amount >= 0.6 * (end - start) {
                seconds[name, default: 0] += amount
                turns[name, default: 0] += 1
            }
        }
        let supported = seconds.filter { $0.value >= 3 && turns[$0.key, default: 0] >= 2 }
        let total = seconds.values.reduce(0, +)
        guard total >= 6, duration > 0, total / duration >= 0.7 else { return [] }
        if let best = supported.max(by: { $0.value < $1.value }), best.value / total >= 0.85 {
            return [best.key]
        }
        return supported.count > 1 ? supported.keys.sorted() : []
    }

    private static func rejectDuplicateNames(_ result: inout RecordingVoices) {
        let groups = Dictionary(grouping: result.voices.filter { $0.name != nil }, by: { normalized($0.name!) })
        for index in result.voices.indices {
            let voice = result.voices[index]
            guard let name = voice.name, groups[normalized(name), default: []].count > 1,
                  let evidence = voice.identityEvidence else { continue }
            result.voices[index].name = nil
            result.voices[index].identityEvidence = SpeakerIdentityEvidence(
                callNames: evidence.callNames, voiceprintName: evidence.voiceprintName, conflict: true)
        }
    }

    private static func normalized(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
