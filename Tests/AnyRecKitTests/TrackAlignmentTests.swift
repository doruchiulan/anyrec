import Foundation
import Testing

@testable import AnyRecKit

/// A small deterministic generator, so a synthetic call is the same call every run.
private struct Seeded {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

/// A synthetic call as 20 ms envelope frames: the far end and the owner taking turns in
/// phrases of a second or two, room noise under both, and optionally the far end coming
/// back through the microphone `echoLag` frames after the system track has it.
private struct SyntheticCall {
    let system: AudioEnvelope
    let microphone: AudioEnvelope

    /// `late`: frames the system track's stamps trail the room (positive = system late).
    init(seconds: Double = 300, late: Int, echo: Double?, seed: UInt64 = 7) {
        var random = Seeded(state: seed)
        let count = Int(seconds / AudioEnvelope.frameDuration)
        var far = [Double](repeating: 0, count: count)
        var owner = [Double](repeating: 0, count: count)
        var index = 0
        var farTurn = true
        while index < count {
            let length = 40 + Int(random.next() * 120)
            /// Speech: syllables of a few frames at their own loudness, with the short
            /// silences between words that give an envelope its shape.
            var frame = index
            while frame < min(count, index + length) {
                let syllable = 0.3 + 0.7 * random.next()
                for at in frame..<min(count, frame + 3 + Int(random.next() * 12)) {
                    if farTurn { far[at] = 3_000 * syllable } else { owner[at] = 2_000 * syllable }
                }
                frame += 5 + Int(random.next() * 20)
            }
            index += length + Int(random.next() * 30)
            if random.next() < 0.6 { farTurn.toggle() }
        }
        /// The system track holds the far end as heard in the room, stamped `late` frames later.
        let stamped = (0..<count).map { frame in frame - late >= 0 && frame - late < count ? far[frame - late] : 0 }
        system = AudioEnvelope(frames: stamped.map { $0 + 2 })
        microphone = AudioEnvelope(frames: (0..<count).map { frame in
            let room = 30 + 20 * random.next()
            return owner[frame] + room + (echo.map { far[frame] * $0 } ?? 0)
        })
    }
}

@Suite("Track alignment")
struct TrackAlignmentTests {
    @Test("finds a late system track from the echo, to within a few milliseconds", arguments: [25, 3, 0])
    func late(frames: Int) throws {
        let call = SyntheticCall(late: frames, echo: 0.2)
        let offset = TrackAlignment.measure(reference: call.microphone, other: call.system)
        let seconds = try #require(offset.seconds)
        #expect(abs(seconds - Double(frames) * AudioEnvelope.frameDuration) < 0.005)
        #expect(offset.confidence > 0.45)
        #expect(offset.windowsUsed == offset.windowsTried)
    }

    @Test("finds an early system track: a negative offset")
    func early() throws {
        let call = SyntheticCall(late: -10, echo: 0.2)
        let seconds = try #require(TrackAlignment.measure(reference: call.microphone, other: call.system).seconds)
        #expect(abs(seconds + 0.2) < 0.005)
    }

    @Test("is not measurable without echo, turn-taking or not")
    func noEcho() {
        for seed in [1, 2, 3] as [UInt64] {
            let call = SyntheticCall(late: 25, echo: nil, seed: seed)
            let offset = TrackAlignment.measure(reference: call.microphone, other: call.system)
            #expect(offset.seconds == nil)
            #expect(offset.windowsTried > 1)
            #expect(offset.confidence < TrackAlignment.minimumCorrelation)
        }
    }

    @Test("survives turn-taking with a faint echo")
    func faintEcho() throws {
        let call = SyntheticCall(late: 25, echo: 0.1)
        let seconds = try #require(TrackAlignment.measure(reference: call.microphone, other: call.system).seconds)
        #expect(abs(seconds - 0.5) < 0.01)
    }

    @Test("a recording too short for one window is not measurable")
    func short() {
        let call = SyntheticCall(seconds: 15, late: 25, echo: 0.2)
        let offset = TrackAlignment.measure(reference: call.microphone, other: call.system)
        #expect(offset.seconds == nil && offset.windowsTried == 0)
    }

    @Test("one strong window among weak ones is a coincidence, not an offset")
    func lonelyWindow() {
        /// Echo only in the first 50 s of a five-minute call.
        let call = SyntheticCall(late: 25, echo: 0.2)
        let quiet = SyntheticCall(late: 25, echo: nil)
        let cut = Int(50 / AudioEnvelope.frameDuration)
        let mic = AudioEnvelope(frames: Array(call.microphone.frames[..<cut]) + quiet.microphone.frames[cut...])
        let offset = TrackAlignment.measure(reference: mic, other: call.system)
        #expect(offset.seconds == nil)
    }

    @Test("moves an envelope earlier or later, padding with silence and interpolating fractions")
    func advanced() {
        let envelope = AudioEnvelope(frames: [1, 2, 3, 4])
        let step = AudioEnvelope.frameDuration
        #expect(envelope.advanced(by: step).frames == [2, 3, 4, 0])
        #expect(envelope.advanced(by: -2 * step).frames == [0, 0, 1, 2])
        #expect(envelope.advanced(by: step / 2).frames == [1.5, 2.5, 3.5, 2])
        #expect(envelope.advanced(by: 0) == envelope)
    }
}

@Suite("Alignment in the mixes")
struct AlignedMixTests {
    private let sum = "amix=inputs=2:duration=longest:normalize=0[a]"

    @Test("a late system track is trimmed before it is summed, gained or used as the duck's key")
    func trimmed() {
        let matched = MixPlan(balance: .matched(TrackGains(systemAudio: -2, microphone: 0)),
                              alignment: .init(systemAudio: 0.512))
        #expect(matched.filter(systemAudio: 1, microphone: 0)
                == "[1:a]atrim=start=0.5120,asetpts=PTS-STARTPTS[sys];[sys]volume=-2.0dB[g1];[0:a][g1]" + sum)
        let ducked = MixPlan(balance: .duckedMicrophone, alignment: .init(systemAudio: 0.512))
        #expect(ducked.filter(systemAudio: 1, microphone: 0)
                == "[1:a]atrim=start=0.5120,asetpts=PTS-STARTPTS[sys];[sys]asplit[key][call];"
                + "[0:a][key]\(MixPlan.duck)[mic];[call][mic]" + sum)
    }

    @Test("an early track is delayed, and a moved microphone is moved before it is gated")
    func delayedAndGated() {
        let live = MicrophoneLive(duration: 10, spans: [1..<2])
        let plan = MixPlan(balance: .matched(.none), microphoneLive: live,
                           alignment: .init(systemAudio: -0.06, microphone: 0.021), microphoneTrack: .clean)
        #expect(plan.filter(systemAudio: 1, microphone: 0)
                == "[1:a]adelay=delays=60.000:all=1[sys];"
                + "[0:a]atrim=start=0.0210,asetpts=PTS-STARTPTS[mic0];"
                + "[mic0]volume=0:enable='not(between(t,1.00,2.00))'[live];[live][sys]" + sum)
    }

    @Test("no stage at all for an offset under half a millisecond")
    func negligible() {
        let plan = MixPlan(balance: .matched(.none), alignment: .init(systemAudio: 0.0002))
        #expect(plan.filter(systemAudio: 1, microphone: 2) == "[1:a][2:a]" + sum)
    }

    @Test("the microphone alone, as the duck leaves it, for the echo check")
    func microphoneOnly() {
        let ducked = MixPlan(balance: .duckedMicrophone, alignment: .init(systemAudio: 0.5))
        #expect(ducked.microphoneFilter(systemAudio: 0, microphone: 1)
                == "[0:a]atrim=start=0.5000,asetpts=PTS-STARTPTS[sys];[sys]asplit[key][call];"
                + "[1:a][key]\(MixPlan.duck)[mic];[call]anullsink;[mic]anull[a]")
        let matched = MixPlan(balance: .matched(.none), alignment: .init(systemAudio: 0.5, microphone: 0.01))
        #expect(matched.microphoneFilter(systemAudio: 0, microphone: 1)
                == "[1:a]atrim=start=0.0100,asetpts=PTS-STARTPTS[mic0];[mic0]anull[a]")
    }

    @Test("the merged file is built from the aligned plan, and from the clean microphone when the plan says so")
    func merge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-align-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try OutputPlan.create(in: root, named: "rec-test")
        for url in [plan.systemAudio, plan.microphone, plan.cleanMicrophone] { try Data(count: 2_048).write(to: url) }
        let job = try await Muxer.job(for: plan, microphone: .clean)
        #expect(job.audio == [plan.systemAudio, plan.cleanMicrophone])
        let mix = MixPlan(balance: .duckedMicrophone, alignment: .init(systemAudio: 0.25), microphoneTrack: .clean)
        let arguments = Muxer.arguments(for: job, mix: mix, writingTo: root.appendingPathComponent("out.m4a"))
        let graph = try #require(arguments.firstIndex(of: "-filter_complex").map { arguments[$0 + 1] })
        #expect(graph.hasPrefix("[0:a]atrim=start=0.2500,asetpts=PTS-STARTPTS[sys];[sys]asplit"))
        #expect(arguments.contains(plan.cleanMicrophone.path))
        #expect(try await Muxer.job(for: plan).audio == [plan.systemAudio, plan.microphone])
    }

    @Test("the engines' mix takes the plan's microphone and moves the tracks the same way")
    func transcriptMix() {
        let plan = MixPlan(balance: .matched(.none), alignment: .init(systemAudio: 0.3))
        let directory = URL(fileURLWithPath: "/tmp/rec-x")
        let arguments = AudioMix.arguments(microphone: directory.appendingPathComponent("microphone-clean.m4a"),
                                           systemAudio: directory.appendingPathComponent("system-audio.m4a"),
                                           plan: plan, output: directory.appendingPathComponent("mix.wav"))
        #expect(arguments.contains("/tmp/rec-x/microphone-clean.m4a"))
        #expect(arguments[arguments.firstIndex(of: "-filter_complex")! + 1]
                == "[1:a]atrim=start=0.3000,asetpts=PTS-STARTPTS[sys];[0:a][sys]" + sum)
        #expect(MixPlan.MicrophoneTrack.clean.url(besideRaw: directory.appendingPathComponent("microphone.m4a"))
                == directory.appendingPathComponent("microphone-clean.m4a"))
    }

    @Test("a moved track is that much shorter, so the merge is verified against the right length")
    func length() {
        let plan = MixPlan(balance: .matched(.none), alignment: .init(systemAudio: 0.5, microphone: -0.1))
        #expect(plan.length(of: 60, systemAudio: true) == 59.5)
        #expect(abs(plan.length(of: 60, systemAudio: false) - 60.1) < 1e-9)
    }

    @Test("speech regions and the bleed check read the envelopes lined up")
    func envelopes() {
        let step = AudioEnvelope.frameDuration
        /// The far end in the room at frames 2–3; the system track stamps it at 4–5.
        let system = AudioEnvelope(frames: [0, 0, 0, 0, 1_000, 1_000, 0, 0])
        let mic = AudioEnvelope(frames: [0, 0, 300, 300, 0, 0, 0, 0])
        let plan = MixPlan(balance: .duckedMicrophone, alignment: .init(systemAudio: 2 * step))
        let lined = plan.aligned(systemAudio: system, microphone: mic)
        #expect(lined.systemAudio.frames == [0, 0, 1_000, 1_000, 0, 0, 0, 0])
        let heard = plan.envelope(systemAudio: lined.systemAudio, microphone: lined.microphone)
        /// The echo falls under the duck once lined up: the mix is the far end alone.
        #expect(heard.frames[2] == 1_000 && heard.frames[3] == 1_000)
        let unaligned = MixPlan(balance: .duckedMicrophone).envelope(systemAudio: system, microphone: mic)
        #expect(unaligned.frames[2] == 300)
    }
}

@Suite("Attribution on aligned tracks")
struct AlignedAttributionTests {
    /// The owner talks 1–2 s; the far end 2–3 s in the room, loud in the microphone (a
    /// speakerphone), but stamped half a second late on the system track.
    private func tracks() -> (system: AudioEnvelope, mic: AudioEnvelope) {
        let frames = Int(4 / AudioEnvelope.frameDuration)
        let time = { (index: Int) in AudioEnvelope.time(of: index) }
        let system = AudioEnvelope(frames: (0..<frames).map { (2.5..<3.5).contains(time($0)) ? 1_000 : 1 })
        let mic = AudioEnvelope(frames: (0..<frames).map { index -> Double in
            if (1..<2).contains(time(index)) { return 800 }
            if (2..<3).contains(time(index)) { return 900 }
            return 5
        })
        return (system, mic)
    }

    @Test("a far-end line said into a late system track is the call's once lined up, and the owner's line stays theirs")
    func farEnd() {
        let (system, mic) = tracks()
        let lines = [Utterance(start: 1.0, end: 2.0, text: "Mine."), Utterance(start: 2.0, end: 3.0, text: "Theirs.")]
        let plan = MixPlan(balance: .matched(.none), alignment: .init(systemAudio: 0.5))
        let lined = plan.aligned(systemAudio: system, microphone: mic)
        let aligned = SpeakerAttribution.label(lines, microphone: lined.microphone, systemAudio: lined.systemAudio, mix: plan)
        #expect(aligned.map(\.speaker) == [.me, .others])
        /// Unaligned, half the far end's line has no call audio under it and the echo wins it.
        let unaligned = SpeakerAttribution.label(lines, microphone: mic, systemAudio: system, mix: .plain)
        #expect(unaligned.map(\.speaker) == [.me, .me])
    }

    @Test("the owner merge's microphone reads the lined-up tracks")
    func ownerMerge() throws {
        let (system, mic) = tracks()
        let plan = MixPlan(balance: .matched(.none), alignment: .init(systemAudio: 0.5))
        let lined = plan.aligned(systemAudio: system, microphone: mic)
        let microphone = try #require(SpeakerAttribution.Microphone(
            microphone: lined.microphone, systemAudio: lined.systemAudio, mix: plan))
        #expect(microphone.speaks(from: 1.0, to: 2.0))
    }
}
