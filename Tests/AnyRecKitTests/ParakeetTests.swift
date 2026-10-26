import Foundation
import Testing

@testable import AnyRecKit

@Suite("Parakeet lines")
struct ParakeetLineTests {
    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval)
        -> (text: String, start: TimeInterval, end: TimeInterval)
    {
        (text, start, end)
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
