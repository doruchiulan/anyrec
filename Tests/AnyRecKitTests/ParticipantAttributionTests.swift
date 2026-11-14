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

    private var library: VoiceLibrary {
        VoiceLibrary(people: [.init(name: "Alex", prints: [[1, 0]]), .init(name: "Costin", prints: [[0, 1]], aliases: ["Costin Pop"])])
    }

    @Test("A call name that belongs to someone else in the library is a conflict, with both clues kept")
    func conflict() throws {
        let resolved = ParticipantAttribution.resolve(voices(name: "Alex"), lines: lines,
                                                      evidence: observations("Costin Pop"), library: library, microphone: nil)
        var result = try #require(resolved.voices)
        #expect(result.names.isEmpty)
        #expect(result.unnamed.count == 1)
        #expect(result.voices[0].identityEvidence?.callNames == ["Costin Pop"])
        #expect(result.voices[0].identityEvidence?.voiceprintName == "Alex")
        #expect(result.voices[0].identityEvidence?.conflict == true)
        #expect(resolved.aliases.isEmpty)
        result.name("A", "Costin")
        #expect(result.names == ["A": "Costin"])
        #expect(result.voices[0].identityEvidence == nil)
    }

    @Test("A display name corroborating a voiceprint is agreement: the saved name stays and the display name becomes an alias")
    func agreement() {
        let same = ParticipantAttribution.resolve(voices(name: "Costin"), lines: lines, evidence: observations("COSTIN"),
                                                  library: library, microphone: nil)
        #expect(same.voices?.names == ["A": "Costin"])
        #expect(same.aliases.isEmpty)
        let nickname = ParticipantAttribution.resolve(voices(name: "Alex"), lines: lines, evidence: observations("Alexandru Ionescu"),
                                                      library: library, microphone: nil)
        #expect(nickname.voices?.names == ["A": "Alex"])
        #expect(nickname.voices?.voices[0].identityEvidence?.conflict == false)
        #expect(nickname.voices?.voices[0].identityEvidence?.callName == "Alexandru Ionescu")
        #expect(nickname.aliases.map(\.display) == ["Alexandru Ionescu"] && nickname.aliases.map(\.person) == ["Alex"])
        let known = ParticipantAttribution.resolve(voices(name: "Costin"), lines: lines, evidence: observations("Costin Pop"),
                                                   library: library, microphone: nil)
        #expect(known.voices?.names == ["A": "Costin"] && known.aliases.isEmpty)
    }

    @Test("A voice named only by the call window takes the display name, or the saved name it is an alias of, and files nothing")
    func callOnly() {
        let display = ParticipantAttribution.resolve(voices(), lines: lines, evidence: observations("Sam Rivers"),
                                                     library: library, microphone: nil)
        #expect(display.voices?.names == ["A": "Sam Rivers"])
        #expect(display.aliases.isEmpty)
        let alias = ParticipantAttribution.resolve(voices(), lines: lines, evidence: observations("Costin Pop"),
                                                   library: library, microphone: nil)
        #expect(alias.voices?.names == ["A": "Costin"])
    }

    @Test("Evidence is scored where it exists: a window readable only at the start still names the voice")
    func partialReadability() {
        let long = lines + (2..<20).map {
            Utterance(start: Double($0 * 7), end: Double($0 * 7 + 6), text: "Later turn", speaker: .voice("A"))
        }
        var evidence = observations("Costin")
        evidence.observations += (14..<140).map { .init(at: Double($0), source: "", participants: [], speaking: []) }
        let result = ParticipantAttribution.apply(voices(), lines: long, evidence: evidence)
        #expect(result?.names == ["A": "Costin"])
        #expect((result?.voices[0].identityEvidence?.agreement ?? 0) > 0.99)
    }

    @Test("Polls marking several people agree with a name but cannot supply one")
    func severalSpeakers() {
        func polls(_ speaking: [[String]]) -> CallParticipants {
            CallParticipants(observations: speaking.enumerated().map {
                .init(at: Double($0.offset), source: "teams:1:2", participants: ["Alex", "Costin", "Sam"], speaking: $0.element)
            })
        }
        let lines = (0..<4).map { Utterance(start: Double($0 * 7), end: Double($0 * 7 + 6), text: "Turn", speaker: .voice("A")) }
        let onlyMany = polls(Array(repeating: ["Alex", "Costin"], count: 28))
        #expect(ParticipantAttribution.apply(voices(), lines: lines, evidence: onlyMany)?.names.isEmpty == true)
        let agreeing = polls(Array(repeating: ["Alex"], count: 14) + Array(repeating: ["Alex", "Costin"], count: 14))
        #expect(ParticipantAttribution.apply(voices(), lines: lines, evidence: agreeing)?.names == ["A": "Alex"])
        let disagreeing = polls(Array(repeating: ["Alex"], count: 14) + Array(repeating: ["Costin", "Sam"], count: 14))
        #expect(ParticipantAttribution.apply(voices(), lines: lines, evidence: disagreeing)?.names.isEmpty == true)
    }

    @Test("A Call line with no voice takes the person the window showed, when that person is a voice here")
    func callLines() throws {
        let gap = Utterance(start: 14, end: 18, text: "Unclustered", speaker: .others)
        let stray = Utterance(start: 20, end: 24, text: "Nobody shown", speaker: .others)
        let evidence = observations("Costin", seconds: 0...18)
        let resolved = ParticipantAttribution.resolve(voices(), lines: lines + [gap, stray], evidence: evidence,
                                                      library: VoiceLibrary(), microphone: nil)
        #expect(resolved.lines.map(\.speaker) == [.voice("A"), .voice("A"), .voice("A"), .others])
        #expect(resolved.voices?.callLinesNamed == 1)
    }

    @Test("The person recording heard as a far-end voice goes back to Me only where the microphone speaks and nobody else is shown")
    func ownerVoice() throws {
        var owner = RecordingVoices.Voice(letter: "A", print: [1, 0], sample: "Mine", start: 0, end: 6)
        owner.microphoneShare = 0.8
        owner.microphoneSeconds = 20
        let other = RecordingVoices.Voice(letter: "B", print: [0, 1], sample: "Theirs", start: 30, end: 36)
        let lines = [
            Utterance(start: 0, end: 6, text: "Spoken into the mic", speaker: .voice("A")),
            Utterance(start: 10, end: 16, text: "Mic silent here", speaker: .voice("A")),
            Utterance(start: 20, end: 26, text: "Window shows Sam", speaker: .voice("A")),
            Utterance(start: 30, end: 36, text: "Sam speaking", speaker: .voice("B")),
            Utterance(start: 37, end: 43, text: "Sam again", speaker: .voice("B")),
        ]
        let frames = (0..<2_000).map { index -> Double in
            let time = Double(index) * 0.02
            return (time < 6 || (time >= 20 && time < 26)) ? 3_000 : 10
        }
        let microphone = SpeakerAttribution.Microphone(heard: AudioEnvelope(frames: frames), talking: 100)
        let evidence = CallParticipants(observations: (19...44).map {
            .init(at: Double($0), source: "teams:1:2", participants: ["Sam"], speaking: ["Sam"])
        })
        let resolved = ParticipantAttribution.resolve(RecordingVoices(voices: [owner, other]), lines: lines, evidence: evidence,
                                                      library: VoiceLibrary(), microphone: microphone)
        #expect(resolved.lines.map(\.speaker) == [.me, .others, .voice("A"), .voice("A"), .voice("A")])
        #expect(resolved.voices?.voices.map(\.letter) == ["A"])
        #expect(resolved.voices?.names == ["A": "Sam"])
        #expect(resolved.voices?.ownerMerge?.toMe == 1)
        #expect(resolved.voices?.ownerMerge?.toOthers == 2)
        #expect(resolved.voices?.ownerMerge?.evidence == [.microphone])
    }

    @Test("Whoever the window shows during Me lines is the person recording, and a voice it names goes back to them")
    func ownerFromWindow() throws {
        let me = (0..<3).map { Utterance(start: Double($0 * 7), end: Double($0 * 7 + 6), text: "Mine", speaker: .me) }
        let echo = (3..<6).map { Utterance(start: Double($0 * 7), end: Double($0 * 7 + 6), text: "Also mine", speaker: .voice("A")) }
        let evidence = CallParticipants(observations: (0...42).map {
            .init(at: Double($0), source: "slack:1:2", participants: ["Alex Ionescu", "Sam"], speaking: ["Alex Ionescu"])
        })
        let microphone = SpeakerAttribution.Microphone(heard: AudioEnvelope(frames: Array(repeating: 3_000, count: 3_000)), talking: 100)
        let resolved = ParticipantAttribution.resolve(voices(), lines: me + echo, evidence: evidence,
                                                      library: VoiceLibrary(), microphone: microphone)
        #expect(resolved.lines.allSatisfy { $0.speaker == .me })
        #expect(resolved.voices?.voices.isEmpty == true)
        #expect(resolved.voices?.ownerMerge?.evidence == [.callWindow])
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

    @Test("Two people under one diarization letter are recorded as a possible fusion, not split or renamed")
    func fusedVoices() {
        let extended = lines + lines.map { Utterance(start: $0.start + 14, end: $0.end + 14, text: $0.text, speaker: $0.speaker) }
        let evidence = CallParticipants(observations: observations("Alex").observations
            + observations("Costin", seconds: 14...27).observations)
        let result = ParticipantAttribution.apply(voices(name: "Alex"), lines: extended, evidence: evidence)
        #expect(result?.names == ["A": "Alex"])
        #expect(result?.voices[0].identityEvidence?.callNames == ["Alex", "Costin"])
        #expect(result?.voices[0].identityEvidence?.fusedNames == ["Alex", "Costin"])
        #expect(result?.voices[0].identityEvidence?.conflict == false)
        let unnamed = ParticipantAttribution.apply(voices(), lines: extended, evidence: evidence)
        #expect(unnamed?.names.isEmpty == true)
        #expect(unnamed?.voices[0].identityEvidence?.conflict == true)
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
            .init(at: 1, source: "one", participants: ["Alex", "Costin"], speaking: ["Costin"]),
            .init(at: 1, source: "one", participants: [], speaking: ["Alex"]),
            .init(at: -1, source: "one", participants: ["Alex"], speaking: ["Alex"]),
        ]
        for next in invalid { #expect(CallParticipants(observations: [first, next]).spans.isEmpty) }
        let ordered = observations("Alex").observations
        #expect(CallParticipants(observations: ordered + ordered).spans.isEmpty)
        let several = CallParticipants.Observation(at: 1, source: "one", participants: ["Alex", "Costin"], speaking: ["Alex", "Costin"])
        #expect(CallParticipants(observations: [first, several]).spans.map(\.names) == [["Alex"]])
        let both = CallParticipants.Observation(at: 2, source: "one", participants: ["Alex", "Costin"], speaking: ["Alex", "Costin"])
        #expect(CallParticipants(observations: [several, both]).spans.map(\.names) == [["Alex", "Costin"]])
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
