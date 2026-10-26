import Testing

@testable import AnyRecKit

@Suite("VoiceSeparation")
struct VoiceSeparationTests {
    private func line(_ start: Double, _ end: Double, _ text: String, _ speaker: Speaker = .others)
        -> Utterance
    {
        Utterance(start: start, end: end, text: text, speaker: speaker)
    }

    /// Two far-end voices and you, as a diarizer would hear the mix: S2 first.
    private let segments = [
        VoiceSegment(voice: "S2", start: 0, end: 4),
        VoiceSegment(voice: "S1", start: 4, end: 8),
        VoiceSegment(voice: "S3", start: 8, end: 10),
        VoiceSegment(voice: "S2", start: 10, end: 14),
    ]
    private let prints: [String: Voiceprint] = ["S1": [0, 1], "S2": [1, 0], "S3": [0.5, 0.5]]

    @Test("letters voices by first appearance and gives each line the voice heard longest")
    func assigns() {
        let lines = [
            line(0, 3, "First"), line(3.5, 7, "Second, mostly S1"),
            line(10, 12, "Back to the first voice"),
        ]

        let (assigned, voices) = VoiceSeparation.assign(lines, segments: segments, prints: prints)

        #expect(assigned.map(\.speaker) == [.voice("A"), .voice("B"), .voice("A")])
        #expect(voices.voices.map(\.letter) == ["A", "B"])
        #expect(voices.voices[0].print == [1, 0])
        #expect(voices.voices[0].sample == "Back to the first voice")
    }

    @Test("leaves your lines yours, and a line nobody was heard on with the call")
    func keepsMeAndSilence() {
        let lines = [line(8, 10, "Me talking", .me), line(20, 22, "Nobody here")]

        let (assigned, voices) = VoiceSeparation.assign(lines, segments: segments, prints: prints)

        #expect(assigned.map(\.speaker) == [.me, .others])
        #expect(voices.voices.isEmpty)
    }

    @Test("names the voices the library knows and leaves the rest lettered")
    func recognises() {
        var library = VoiceLibrary()
        library.enroll("Sarah", [0, 1])
        var (_, voices) = VoiceSeparation.assign(
            [line(0, 3, "a"), line(4, 7, "b")], segments: segments, prints: prints)

        VoiceSeparation.recognise(&voices, in: library)

        #expect(voices.names == ["B": "Sarah"])
        #expect(voices.unnamed.map(\.letter) == ["A"])
    }

    @Test("cuts a paragraph two voices shared at the sentence end, and leaves one voice's whole")
    func cutsSharedParagraph() {
        /// 0–8 s: S2 for the first half, S1 for the second; the text splits 50/50.
        let shared = line(0, 8, "One voice here. Then another.")
        let whole = line(10, 14, "All one voice. Still the same.")

        let (assigned, _) = VoiceSeparation.assign(
            [shared, whole], segments: segments, prints: prints)

        #expect(
            assigned.map(\.text)
                == ["One voice here.", "Then another.", "All one voice. Still the same."])
        #expect(assigned.map(\.speaker) == [.voice("A"), .voice("B"), .voice("A")])
    }

    @Test("runs past Z into numbers")
    func letters() {
        #expect(VoiceSeparation.letter(0) == "A")
        #expect(VoiceSeparation.letter(25) == "Z")
        #expect(VoiceSeparation.letter(26) == "27")
    }
}
