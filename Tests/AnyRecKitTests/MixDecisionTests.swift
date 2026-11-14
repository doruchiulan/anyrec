import Foundation
import Testing
@testable import AnyRecKit

@Suite("Mix decision kept beside the tracks")
struct MixDecisionTests {
    private func recording() throws -> OutputPlan {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-mix-\(UUID())")
        let plan = try OutputPlan.create(in: root, named: "rec-test")
        try Data(repeating: 1, count: 2_048).write(to: plan.microphone)
        try Data(repeating: 2, count: 2_048).write(to: plan.systemAudio)
        return plan
    }

    @Test("a stored decision is used while the tracks and the mute record are unchanged")
    func reused() throws {
        let plan = try recording()
        defer { try? FileManager.default.removeItem(at: plan.directory.deletingLastPathComponent()) }
        MixDecision(basis: .of(plan), bleeding: true, microphoneLoudness: nil, systemAudioLoudness: nil)
            .write(in: plan.directory)
        #expect(MixPlan.decided(for: plan, using: "/usr/bin/false").balance == .duckedMicrophone)
    }

    @Test("changing a track or microphone-live.json makes it decide again, and keeps the new answer")
    func invalidated() throws {
        let plan = try recording()
        defer { try? FileManager.default.removeItem(at: plan.directory.deletingLastPathComponent()) }
        MixDecision(basis: .of(plan), bleeding: true, microphoneLoudness: nil, systemAudioLoudness: nil)
            .write(in: plan.directory)
        try MicrophoneLive(duration: 10, spans: [0..<5]).write(to: plan.microphoneLive)
        let decided = MixPlan.decided(for: plan, using: "/usr/bin/false")
        #expect(decided.balance == .matched(.none))
        #expect(decided.microphoneLive?.spans == [0..<5])
        #expect(MixDecision.read(in: plan.directory)?.basis == .of(plan))
        #expect(MixDecision.read(in: plan.directory)?.bleeding == false)
    }

    @Test("gains come from the stored loudness")
    func gains() throws {
        let plan = try recording()
        defer { try? FileManager.default.removeItem(at: plan.directory.deletingLastPathComponent()) }
        let system = Loudness(integrated: -29.1, truePeak: -16.2), mic = Loudness(integrated: -42.5, truePeak: -17.6)
        MixDecision(basis: .of(plan), bleeding: false, microphoneLoudness: mic, systemAudioLoudness: system)
            .write(in: plan.directory)
        #expect(MixPlan.decided(for: plan, using: "/usr/bin/false").balance
                == .matched(LoudnessMatch.gains(systemAudio: system, microphone: mic)))
    }

    @Test("the mix's loudness is worked out from the tracks: gated, ducked and gained as the mix is")
    func envelope() {
        let system = AudioEnvelope(frames: [0, 0, 1_000, 1_000, 0, 0, 0, 0])
        let mic = AudioEnvelope(frames: [500, 500, 500, 500, 500, 500, 500, 500])
        let ducked = MixPlan(balance: .duckedMicrophone).envelope(systemAudio: system, microphone: mic)
        #expect(ducked.frames[0] == 500)
        #expect(ducked.frames[2] == 1_000)
        #expect(ducked.frames[3] == 1_000)
        let frame = AudioEnvelope.frameDuration
        let gated = MixPlan(balance: .matched(.none), microphoneLive: MicrophoneLive(duration: 1, spans: [0..<(frame * 2)]))
            .envelope(systemAudio: system, microphone: mic)
        #expect(gated.frames[0] == 500 && gated.frames[5] == 0)
        let boosted = MixPlan(balance: .matched(TrackGains(systemAudio: 0, microphone: 20))).envelope(systemAudio: system, microphone: mic)
        #expect(abs(boosted.frames[0] - 5_000) < 0.01)
    }
}

@Suite("Diarization kept beside the tracks")
struct DiarizationCacheTests {
    @Test("the same audio is diarized once; different audio is diarized again")
    func keyedToAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-diarize-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mix = directory.appendingPathComponent("mix.wav")
        try Data(repeating: 7, count: 10_000).write(to: mix)
        let calls = Counter()
        let diarize: (URL) async throws -> DiarizationCache.Heard = { _ in
            await calls.bump()
            return ([VoiceSegment(voice: "S1", start: 0, end: 2)], ["S1": [1, 0]])
        }
        let first = try await DiarizationCache.heard(mix, in: directory, diarize: diarize)
        let second = try await DiarizationCache.heard(mix, in: directory, diarize: diarize)
        #expect(first.segments == second.segments && second.prints == ["S1": [1, 0]])
        #expect(await calls.count == 1)
        try Data(repeating: 8, count: 10_000).write(to: mix)
        _ = try await DiarizationCache.heard(mix, in: directory, diarize: diarize)
        #expect(await calls.count == 2)
        _ = try await DiarizationCache.heard(mix, in: nil, diarize: diarize)
        #expect(await calls.count == 3)
    }
}

private actor Counter {
    private(set) var count = 0
    func bump() { count += 1 }
}
