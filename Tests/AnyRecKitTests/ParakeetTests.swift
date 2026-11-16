import Foundation
import Testing

@testable import AnyRecKit

@Suite("Parakeet lines")
struct ParakeetLineTests {
    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> Speech.Word {
        Speech.Word(text: text, start: start, end: end)
    }

    @Test("ends a line at a sentence end once it has run a moment")
    func sentences() {
        let lines = ParakeetTranscriber.utterances(from: [
            word("Da.", 0, 0.3), word("Sunt", 0.4, 0.6), word("bine,", 0.6, 0.9), word("mulţumesc.", 0.9, 1.8),
            word("Tu?", 2.0, 2.4),
        ])
        #expect(lines.map(\.text) == ["Da. Sunt bine, mulţumesc.", "Tu?"])
        #expect(lines[0].start == 0 && lines[0].end == 1.8)
    }

    @Test("a pause of most of a second ends a line, with or without punctuation")
    func pauses() {
        let lines = ParakeetTranscriber.utterances(from: [
            word("uite", 0, 0.3), word("stau", 0.3, 0.6), word("pe", 1.6, 1.7), word("aici", 1.7, 2.0),
        ])
        #expect(lines.map(\.text) == ["uite stau", "pe aici"])
    }

    @Test("a line never runs past twenty seconds")
    func cap() {
        let words = (0..<30).map { word("w\($0)", TimeInterval($0), TimeInterval($0) + 0.5) }
        let lines = ParakeetTranscriber.utterances(from: words)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.end - $0.start <= 21 })
    }
}

@Suite("Lines cut where the call starts or stops talking")
struct CallTurnsTests {
    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> Speech.Word {
        Speech.Word(text: text, start: start, end: end)
    }

    /// A call track that talks during `spans` and is digitally silent otherwise.
    private func call(talking spans: [Range<TimeInterval>], over duration: TimeInterval = 12) -> AudioEnvelope {
        let count = AudioEnvelope.index(at: duration)
        return AudioEnvelope(frames: (0..<count).map { index in
            let time = AudioEnvelope.time(of: index)
            return spans.contains { $0.contains(time) } ? 3_000 : 1
        })
    }

    @Test("a reply with no pause and no full stop becomes its own line")
    func reply() {
        let words = [
            word("Audio", 0.0, 0.3), word("only.", 0.3, 0.6),
            word("A,", 1.0, 1.2), word("bine,", 1.2, 1.5), word("îi", 1.5, 1.7), word("dau", 1.7, 2.0),
            word("eu", 2.0, 2.2), word("de", 2.2, 3.0), word("fapt", 3.0, 3.3),
            word("Păi", 3.4, 3.6), word("nu,", 3.6, 3.9), word("audio", 3.9, 4.3), word("only", 4.3, 4.8),
        ]
        let cuts = CallTurns.cuts(in: words, systemAudio: call(talking: [1.0..<3.35]))
        #expect(cuts == [2, 9])
        let lines = ParakeetTranscriber.utterances(from: words, cuts: cuts)
        #expect(lines.map(\.text) == ["Audio only.", "A, bine, îi dau eu de fapt", "Păi nu, audio only"])
        #expect(ParakeetTranscriber.utterances(from: words).count == 1, "without the call track it was one line")
    }

    @Test("a short sound from the other side does not cut a sentence")
    func backchannel() {
        let words = (0..<10).map { word("w\($0)", Double($0) * 0.4, Double($0) * 0.4 + 0.35) }
        #expect(CallTurns.cuts(in: words, systemAudio: call(talking: [1.6..<1.9])).isEmpty)
    }

    @Test("nothing is cut without a call track that ever talks")
    func silentCall() {
        let words = (0..<5).map { word("w\($0)", Double($0), Double($0) + 0.5) }
        #expect(CallTurns.cuts(in: words, systemAudio: AudioEnvelope(frames: Array(repeating: 0, count: 400))).isEmpty)
    }
}

@Suite("ffmpeg download")
struct FFmpegSetupTests {
    @Test("is pinned to one build for this architecture, named for where it lands")
    func asset() {
        let asset = FFmpegSetup.asset
        #expect(asset.name == "ffmpeg")
        #expect(asset.sha256.count == 64)
        #expect(asset.url.absoluteString.hasPrefix("https://github.com/eugeneware/ffmpeg-static/releases/download/"))
        #expect(FFmpegSetup.path.lastPathComponent == "ffmpeg")
    }
}
