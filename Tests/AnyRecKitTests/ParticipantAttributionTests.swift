import Foundation
import Testing
@testable import AnyRecKit

@Suite("Call participant evidence")
struct ParticipantAttributionTests {
    private let lines = [
        Utterance(start: 0, end: 6, text: "First turn", speaker: .voice("A")),
        Utterance(start: 7, end: 13, text: "Second turn", speaker: .voice("A")),
    ]

    private func observations(_ name: String, seconds: ClosedRange<Int> = 0...13) -> CallParticipants {
        CallParticipants(observations: seconds.map {
            .init(at: Double($0), source: "teams:123:456", participants: [name], speaking: [name])
        })
    }

    private func voices(name: String? = nil) -> RecordingVoices {
        RecordingVoices(voices: [.init(letter: "A", print: [1, 0], sample: "First turn", start: 0, end: 6, name: name)])
    }

    @Test("Repeated call indicators name a voice without changing its print or turns")
    func namesUnknownVoice() throws {
        let result = try #require(ParticipantAttribution.apply(voices(), lines: lines, evidence: observations("Costin")))
        #expect(result.names == ["A": "Costin"])
        #expect(result.voices[0].print == [1, 0])
        #expect(result.voices[0].identityEvidence?.conflict == false)
        #expect(result.voices[0].start == 0)
    }

    @Test("Conflicting saved voice and call indicator retain both clues for review")
    func conflict() throws {
        var result = try #require(ParticipantAttribution.apply(voices(name: "Alex"), lines: lines,
                                                              evidence: observations("Costin")))
        #expect(result.names.isEmpty)
        #expect(result.unnamed.count == 1)
        #expect(result.voices[0].identityEvidence == .init(callNames: ["Costin"], voiceprintName: "Alex", conflict: true))
        result.name("A", "Costin")
        #expect(result.names == ["A": "Costin"])
        #expect(result.voices[0].identityEvidence == nil)
    }

    @Test("Agreement preserves the saved spelling; aliases are not guessed")
    func agreement() {
        let result = ParticipantAttribution.apply(voices(name: "Costin"), lines: lines, evidence: observations("COSTIN"))
        #expect(result?.names == ["A": "Costin"])
        let alias = ParticipantAttribution.apply(voices(name: "Alex"), lines: lines, evidence: observations("Alexandru"))
        #expect(alias?.names.isEmpty == true)
    }

    @Test("Brief evidence, one turn and missing observations cannot override a saved name")
    func insufficientEvidence() {
        for evidence in [observations("Costin", seconds: 0...2), CallParticipants(observations: []), nil] {
            #expect(ParticipantAttribution.apply(voices(name: "Alex"), lines: lines, evidence: evidence)?.names == ["A": "Alex"])
        }
        #expect(ParticipantAttribution.apply(voices(), lines: [lines[0]], evidence: observations("Costin"))?.names.isEmpty == true)
    }

    @Test("Overlapping speech and Me cannot supply participant identity")
    func overlap() {
        let interrupted = lines + [Utterance(start: 0, end: 13, text: "Other voice", speaker: .voice("B"))]
        #expect(ParticipantAttribution.apply(voices(), lines: interrupted, evidence: observations("Costin"))?.names.isEmpty == true)
        let mine = lines.map { Utterance(start: $0.start, end: $0.end, text: $0.text, speaker: .me) }
        #expect(ParticipantAttribution.apply(voices(), lines: mine, evidence: observations("Costin"))?.names.isEmpty == true)
    }

    @Test("Two people assigned the same diarization letter remain unresolved")
    func fusedVoices() {
        let extended = lines + lines.map { Utterance(start: $0.start + 14, end: $0.end + 14, text: $0.text, speaker: $0.speaker) }
        let evidence = CallParticipants(observations: observations("Alex").observations
            + observations("Costin", seconds: 14...27).observations)
        let result = ParticipantAttribution.apply(voices(name: "Alex"), lines: extended, evidence: evidence)
        #expect(result?.names.isEmpty == true)
        #expect(result?.voices[0].identityEvidence?.callNames == ["Alex", "Costin"])
    }

    @Test("Old voices decode and evidence survives regeneration storage")
    func persistence() throws {
        let old = Data(#"{"voices":[{"letter":"A","print":[],"sample":"Hi","start":0,"end":3}]}"#.utf8)
        #expect(try JSONDecoder().decode(RecordingVoices.self, from: old).voices[0].identityEvidence == nil)
        let result = try #require(ParticipantAttribution.apply(voices(name: "Alex"), lines: lines, evidence: observations("Costin")))
        #expect(try JSONDecoder().decode(RecordingVoices.self, from: JSONEncoder().encode(result)) == result)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try observations("Costin").write(in: directory)
        #expect(CallParticipants.read(in: directory) == observations("Costin"))
    }

    @Test("Gaps, multiple speakers, missing roster entries and different windows supply no span")
    func staleIndicators() {
        let first = CallParticipants.Observation(at: 0, source: "one", participants: ["Alex"], speaking: ["Alex"])
        let invalid: [CallParticipants.Observation] = [
            .init(at: 4, source: "one", participants: ["Alex"], speaking: ["Alex"]),
            .init(at: 1, source: "two", participants: ["Alex"], speaking: ["Alex"]),
            .init(at: 1, source: "one", participants: ["Alex", "Costin"], speaking: ["Alex", "Costin"]),
            .init(at: 1, source: "one", participants: [], speaking: ["Alex"]),
            .init(at: -1, source: "one", participants: ["Alex"], speaking: ["Alex"]),
        ]
        for next in invalid { #expect(CallParticipants(observations: [first, next]).spans.isEmpty) }
        let ordered = observations("Alex").observations
        #expect(CallParticipants(observations: ordered + ordered).spans.isEmpty)
    }

    @Test("One display name cannot automatically identify two separate voices")
    func duplicatedIdentity() {
        let other = lines.map { Utterance(start: $0.start + 14, end: $0.end + 14, text: $0.text, speaker: .voice("B")) }
        var input = voices()
        input.voices.append(.init(letter: "B", print: [0, 1], sample: "Other voice", start: 14, end: 20))
        let result = ParticipantAttribution.apply(input, lines: lines + other, evidence: observations("Alex", seconds: 0...27))
        #expect(result?.names.isEmpty == true)
        #expect(result?.voices.allSatisfy { $0.identityEvidence?.conflict == true } == true)
    }
}
