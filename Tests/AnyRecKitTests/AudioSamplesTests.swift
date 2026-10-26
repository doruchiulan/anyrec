import AVFoundation
import Foundation
import Testing
@testable import AnyRecKit

@Suite("Audio sample windows")
struct AudioSamplesTests {
    @Test("Reads only the requested speaker span and handles the end of the file")
    func window() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("samples-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(url)
        let first = try AudioSamples.read(url, seconds: 1)
        let second = try AudioSamples.read(url, seconds: 1, start: 1)
        #expect(first.count == 16_000)
        #expect(second.count == 16_000)
        #expect(first.allSatisfy { abs($0 - 0.25) < 0.001 })
        #expect(second.allSatisfy { abs($0 + 0.5) < 0.001 })
        #expect(try AudioSamples.read(url, seconds: 10, start: 1.5).count == 8_000)
        #expect(try AudioSamples.read(url, seconds: 1, start: 3).isEmpty)
        #expect(throws: AudioSamples.Failure.self) { try AudioSamples.read(url, seconds: 1, start: .nan) }
    }

    private func writeFixture(_ url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buffer.frameLength = 32_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<32_000 { samples[index] = index < 16_000 ? 0.25 : -0.5 }
        try file.write(from: buffer)
    }
}
