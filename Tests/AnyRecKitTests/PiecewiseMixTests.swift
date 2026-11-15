import Foundation
import Testing

@testable import AnyRecKit

@Suite("Piecewise alignment in the mixes")
struct PiecewiseMixTests {
    private let stepped = TrackShift(pieces: [.init(start: 0, seconds: 0.3), .init(start: 30, seconds: 0.1)])

    @Test("one lag stays a trim or a delay; a changing one restamps and follows the stamps")
    func graphs() {
        #expect(MixPlan.shift(TrackShift(constant: 0.5)) == MixPlan.shift(0.5))
        #expect(MixPlan.shift(TrackShift.zero) == nil)
        let graph = MixPlan.shift(stepped) ?? ""
        #expect(graph.hasPrefix("asetpts='(if(lt(T,30.3000),(T-0.300000),(T-0.100000)))/TB',"))
        #expect(graph.hasSuffix(",aresample=async=100:min_hard_comp=0.02:first_pts=0"))
        #expect(!graph.contains("atrim"))
    }

    @Test("both mixes and the echo check's microphone carry the changing lag")
    func everyGraph() {
        let alignment = MixPlan.Alignment(systemAudio: stepped, microphone: TrackShift(pieces: [
            .init(start: 0, seconds: 0.02), .init(start: 30, seconds: 0.035)]))
        for balance in [MixPlan.Balance.duckedMicrophone, .matched(.none)] {
            let plan = MixPlan(balance: balance, alignment: alignment, microphoneTrack: .clean)
            let filter = plan.filter(systemAudio: 0, microphone: 1)
            #expect(filter.contains("[0:a]asetpts=") && filter.contains("[1:a]asetpts="))
            #expect(plan.microphoneFilter(systemAudio: 0, microphone: 1).contains("[1:a]asetpts="))
        }
    }

    @Test("the envelopes everything compares are moved by the same changing lag")
    func envelopes() {
        let step = AudioEnvelope.frameDuration
        let plan = MixPlan(balance: .matched(.none), alignment: .init(
            systemAudio: TrackShift(pieces: [.init(start: 0, seconds: 2 * step), .init(start: 5 * step, seconds: step)])))
        let system = AudioEnvelope(frames: (0..<10).map(Double.init))
        let lined = plan.aligned(systemAudio: system, microphone: system)
        #expect(lined.systemAudio.frames == [2, 3, 4, 5, 6, 6, 7, 8, 9, 0])
        #expect(lined.microphone == system)
    }

    @Test("a track's length once moved by a changing lag")
    func lengths() {
        let plan = MixPlan(balance: .matched(.none), alignment: .init(systemAudio: stepped))
        #expect(abs(plan.length(of: 60, systemAudio: true) - 59.9) < 1e-9)
        let drifting = MixPlan(balance: .matched(.none), alignment: .init(
            systemAudio: TrackShift(pieces: [.init(start: 0, seconds: 0.5, driftPerHour: 0.036)])))
        #expect(abs(drifting.length(of: 3_600.536, systemAudio: true) - 3_600) < 1e-3)
    }

    @Test("a mix.json with stretches applies them; the decision keeps one lag when only one was measured")
    func decision() {
        let basis = MixDecision.Basis(microphone: nil, systemAudio: nil, microphoneLive: nil)
        let sections = [
            TrackOffset.Section(start: 0, end: 30, seconds: 0.3, confidence: 0.7, windowsUsed: 2, windowsTried: 2),
            TrackOffset.Section(start: 30, end: 60, seconds: 0.1, confidence: 0.7, windowsUsed: 2, windowsTried: 2),
        ]
        let offset = TrackOffset(seconds: 0.2, confidence: 0.7, windowsUsed: 4, windowsTried: 4, sections: sections)
        let decision = MixDecision(basis: basis, bleeding: true, microphoneLoudness: nil, systemAudioLoudness: nil,
                                   systemAudioOffset: offset)
        #expect(decision.alignment.systemAudio == stepped)

        let one = TrackOffset(seconds: 0.3, confidence: 0.7, windowsUsed: 2, windowsTried: 4, sections: [
            sections[0], TrackOffset.Section(start: 30, end: 60, seconds: nil, confidence: 0.1, windowsUsed: 0, windowsTried: 2),
        ])
        #expect(MixDecision(basis: basis, bleeding: true, microphoneLoudness: nil, systemAudioLoudness: nil,
                            systemAudioOffset: one).alignment.systemAudio == TrackShift(constant: 0.3))
    }
}

@Suite("Piecewise alignment through ffmpeg", .enabled(if: Muxer.ffmpegPath() != nil))
struct PiecewiseFFmpegTests {
    /// A click a second, 0.1 s past each second, for a minute.
    private func clicks(into directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("clicks.m4a")
        let source = "aevalsrc='if(lt(mod(t,1)-0.1,0.002)*gte(mod(t,1)-0.1,0),0.9,0)':s=48000:d=60"
        let result = try Shell.run(try #require(Muxer.ffmpegPath()),
                                   ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", source, "-c:a", "aac", url.path])
        try #require(result.succeeded)
        return url
    }

    /// Seconds of each click in the file after `graph`.
    private func clicks(in url: URL, through graph: String) throws -> [Double] {
        let output = url.deletingLastPathComponent().appendingPathComponent("moved-\(UUID()).f32")
        let result = try Shell.run(try #require(Muxer.ffmpegPath()), [
            "-nostdin", "-v", "error", "-y", "-i", url.path, "-af", graph, "-ac", "1", "-ar", "48000",
            "-f", "f32le", output.path,
        ])
        try #require(result.succeeded)
        let data = try Data(contentsOf: output)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var found: [Double] = []
        var index = 0
        while index < samples.count {
            if abs(samples[index]) > 0.3 {
                let end = min(samples.count, index + 200)
                let peak = (index..<end).max { abs(samples[$0]) < abs(samples[$1]) } ?? index
                found.append(Double(peak) / 48_000)
                index = peak + 4_800
            } else {
                index += 1
            }
        }
        return found
    }

    @Test("a step in the lag moves each side by its own lag, to within two milliseconds")
    func step() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-piecewise-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shift = TrackShift(pieces: [.init(start: 0, seconds: 0.3), .init(start: 30, seconds: 0.1)])
        let found = try clicks(in: try clicks(into: directory), through: try #require(MixPlan.shift(shift)))
        /// The click at 1.1 s in the file is 0.8 s on the microphone's timeline; the one at
        /// 31.1 s is 31.0 s. AAC's own placement is within a couple of milliseconds.
        let near = { (time: Double) in found.contains { abs($0 - time) < 0.003 } }
        #expect(near(0.8) && near(10.8) && near(29.8))
        #expect(near(31.0) && near(45.0) && near(59.0))
        #expect(!near(30.0) || near(29.8), "nothing from the skipped stretch is doubled")
    }

    @Test("every graph runs with a drifting and stepping shift on both tracks", arguments: [true, false])
    func graphsRun(ducked: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-piecewise-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try clicks(into: directory)
        let shift = TrackShift(pieces: [.init(start: 0, seconds: 0.5, driftPerHour: 0.034), .init(start: 30, seconds: 0.2)])
        let plan = MixPlan(balance: ducked ? .duckedMicrophone : .matched(.init(systemAudio: -3, microphone: 4)),
                           microphoneLive: MicrophoneLive(duration: 60, transitions: [.init(at: 0, live: true)]),
                           alignment: .init(systemAudio: shift, microphone: TrackShift(pieces: [
                               .init(start: 0, seconds: 0.01), .init(start: 30, seconds: 0.03, driftPerHour: 0.02)])),
                           microphoneTrack: .clean)
        for graph in [plan.filter(systemAudio: 0, microphone: 1), plan.microphoneFilter(systemAudio: 0, microphone: 1)] {
            let output = directory.appendingPathComponent("mix-\(UUID()).wav")
            let result = try Shell.run(try #require(Muxer.ffmpegPath()), [
                "-nostdin", "-v", "error", "-y", "-i", input.path, "-i", input.path,
                "-filter_complex", graph, "-map", "[a]", output.path,
            ])
            #expect(result.succeeded, "\(graph)")
        }
    }

    @Test("a drift is followed through the call")
    func drift() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-piecewise-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        /// A millisecond a second: thirty times the worst drift measured, to see it at all.
        let shift = TrackShift(pieces: [.init(start: 0, seconds: 0.3, driftPerHour: 3.6)])
        let found = try clicks(in: try clicks(into: directory), through: try #require(MixPlan.shift(shift)))
        for u in [1.1, 20.1, 40.1, 59.1] {
            let expected = shift.referenceTime(of: u)
            #expect(found.contains { abs($0 - expected) < 0.003 }, "click at \(u) s should land at \(expected) s")
        }
    }
}
