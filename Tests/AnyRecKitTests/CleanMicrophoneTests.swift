import AVFoundation
import Foundation
import Testing

@testable import AnyRecKit

@Suite("Echo-cancelled microphone")
struct CleanMicrophoneTests {
    private func envelope(_ level: Double, seconds: Double = 60) -> AudioEnvelope {
        let count = Int(seconds / AudioEnvelope.frameDuration)
        return AudioEnvelope(frames: (0..<count).map { $0 % 10 < 3 ? level : level / 20 })
    }

    @Test("a clean track is used when it carries sound, runs the call's length and is not far quieter")
    func usable() {
        let raw = envelope(2_000)
        #expect(CleanMicrophone.usable(envelope(1_200), besideRaw: raw))
        #expect(CleanMicrophone.usable(envelope(1_200), besideRaw: nil))
        /// Missing, silent, cut short, or 40 dB down: the raw track instead.
        #expect(!CleanMicrophone.usable(nil, besideRaw: raw))
        #expect(!CleanMicrophone.usable(AudioEnvelope(frames: []), besideRaw: raw))
        #expect(!CleanMicrophone.usable(envelope(0), besideRaw: raw))
        #expect(!CleanMicrophone.usable(envelope(1_200, seconds: 30), besideRaw: raw))
        #expect(!CleanMicrophone.usable(envelope(20), besideRaw: raw))
    }

    @Test("the recording plan names the clean track beside the raw one")
    func named() {
        let plan = OutputPlan(directory: URL(fileURLWithPath: "/tmp/rec-x"))
        #expect(plan.cleanMicrophone.lastPathComponent == "microphone-clean.m4a")
        #expect(plan.cleanMicrophone.deletingLastPathComponent() == plan.microphone.deletingLastPathComponent())
    }

    @Test("voice processing requires opt-in and the choice reaches capture")
    func setting() {
        var configuration = RecordingConfiguration()
        #expect(!configuration.echoCancellation)
        #expect(!configuration.options.cleanMicrophone)
        #expect(!CaptureOptions().cleanMicrophone)
        configuration.echoCancellation = true
        #expect(configuration.options.cleanMicrophone)
        configuration.echoCancellation = false
        #expect(!configuration.options.cleanMicrophone)
    }

    @Test("buffers handed over by voice processing keep their host time and their samples")
    func sampleBuffer() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        for index in 0..<480 { buffer.floatChannelData![0][index] = Float(index) / 480 }
        let sample = try #require(CleanMicrophone.sampleBuffer(buffer, hostTime: 48_000_000))
        #expect(CMSampleBufferGetNumSamples(sample) == 480)
        let stamped = CMSampleBufferGetPresentationTimeStamp(sample)
        #expect(abs(stamped.seconds - CMClockMakeHostTimeFromSystemUnits(48_000_000).seconds) < 1e-9)
    }
}

@Suite("Mix decision with alignment and the clean microphone")
struct AlignedMixDecisionTests {
    private func recording(clean: Bool = false) throws -> OutputPlan {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-mix2-\(UUID())")
        let plan = try OutputPlan.create(in: root, named: "rec-test")
        try Data(repeating: 1, count: 2_048).write(to: plan.microphone)
        try Data(repeating: 2, count: 2_048).write(to: plan.systemAudio)
        if clean { try Data(repeating: 3, count: 2_048).write(to: plan.cleanMicrophone) }
        return plan
    }

    @Test("a stored offset moves the system track, and the clean track moves only when it is used")
    func stored() throws {
        let plan = try recording(clean: true)
        defer { try? FileManager.default.removeItem(at: plan.directory.deletingLastPathComponent()) }
        let offset = TrackOffset(seconds: 0.512, confidence: 0.9, windowsUsed: 8, windowsTried: 8)
        let clean = TrackOffset(seconds: 0.012, confidence: 0.95, windowsUsed: 8, windowsTried: 8)
        MixDecision(basis: .of(plan), bleeding: false, microphoneLoudness: nil, systemAudioLoudness: nil,
                    systemAudioOffset: offset, cleanMicrophoneOffset: clean, microphoneTrack: .clean)
            .write(in: plan.directory)
        let decided = MixPlan.decided(for: plan, using: "/usr/bin/false")
        #expect(decided.alignment == .init(systemAudio: 0.512, microphone: 0.012))
        #expect(decided.microphoneTrack == .clean)

        MixDecision(basis: .of(plan), bleeding: false, microphoneLoudness: nil, systemAudioLoudness: nil,
                    systemAudioOffset: offset, cleanMicrophoneOffset: clean, microphoneTrack: .raw)
            .write(in: plan.directory)
        #expect(MixPlan.decided(for: plan, using: "/usr/bin/false").alignment == .init(systemAudio: 0.512))
    }

    @Test("not measurable moves nothing")
    func unmeasured() {
        let decision = MixDecision(basis: .init(microphone: nil, systemAudio: nil, microphoneLive: nil),
                                   bleeding: false, microphoneLoudness: nil, systemAudioLoudness: nil,
                                   systemAudioOffset: TrackOffset(seconds: nil, confidence: 0.1, windowsUsed: 0, windowsTried: 8))
        #expect(decision.alignment == .none)
    }

    @Test("a clean track appearing, or a version-1 file, decides again")
    func invalidated() throws {
        let plan = try recording()
        defer { try? FileManager.default.removeItem(at: plan.directory.deletingLastPathComponent()) }
        MixDecision(basis: .of(plan), bleeding: true, microphoneLoudness: nil, systemAudioLoudness: nil)
            .write(in: plan.directory)
        try Data(repeating: 3, count: 2_048).write(to: plan.cleanMicrophone)
        #expect(MixDecision.read(in: plan.directory)?.basis != .of(plan))
        /// The unreadable tracks decide to nothing: no offset, the raw microphone, no duck.
        let decided = MixPlan.decided(for: plan, using: "/usr/bin/false")
        #expect(decided.balance == .matched(.none) && decided.microphoneTrack == .raw && decided.alignment == .none)

        let old = #"{"version":1,"basis":{},"bleeding":true}"#
        try Data(old.utf8).write(to: plan.directory.appendingPathComponent(MixDecision.fileName))
        #expect(MixDecision.read(in: plan.directory) == nil)
    }
}

/// The measurement through ffmpeg on real files: a minute of syllable-shaped noise for the
/// far end, the same 300 ms later on the system track, and its echo in the microphone.
@Suite("Track alignment on encoded tracks", .enabled(if: Muxer.ffmpegPath() != nil))
struct EncodedAlignmentTests {
    private func ffmpeg(_ args: [String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Muxer.ffmpegPath()))
        process.arguments = ["-nostdin", "-v", "error", "-y"] + args
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @Test("the offset is found in the AAC tracks and kept in mix.json")
    func measured() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-align-enc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try OutputPlan.create(in: root, named: "rec-test")
        /// Bursts of noise switched on and off at irregular times stand in for speech.
        let speech = "anoisesrc=color=pink:amplitude=0.5:duration=70:sample_rate=48000:seed=3,"
            + "volume='if(gt(sin(2*PI*t*0.37)+sin(2*PI*t*1.13)+sin(2*PI*t*0.71),0.5),1,0)':eval=frame"
        try #require(try ffmpeg(["-f", "lavfi", "-i", speech + ",adelay=delays=300:all=1",
                                 "-c:a", "aac", plan.systemAudio.path]))
        try #require(try ffmpeg(["-f", "lavfi", "-i", speech + ",volume=0.2",
                                 "-f", "lavfi", "-i", "anoisesrc=color=white:amplitude=0.002:duration=70:sample_rate=48000",
                                 "-filter_complex", "[0:a][1:a]amix=inputs=2:normalize=0", "-c:a", "aac", plan.microphone.path]))
        let decided = MixPlan.decided(for: plan, using: try #require(Muxer.ffmpegPath()))
        #expect(abs((decided.alignment.systemAudio.constant ?? 0) - 0.3) < 0.01)
        let stored = try #require(MixDecision.read(in: plan.directory)?.systemAudioOffset)
        #expect(stored.windowsUsed == stored.windowsTried && stored.confidence > 0.45)
    }
}
