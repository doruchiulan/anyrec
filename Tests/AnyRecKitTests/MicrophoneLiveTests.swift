import Foundation
import Testing

@testable import AnyRecKit

@Suite("MicrophoneLive")
struct MicrophoneLiveTests {
    private typealias Transition = MicrophoneLive.Transition

    @Test("opens a span on unmute, closes it on mute, and closes the last one at the end")
    func spansFromTransitions() {
        let live = MicrophoneLive(
            duration: 100,
            transitions: [
                Transition(at: 10, live: true), Transition(at: 20, live: false),
                Transition(at: 50, live: true),
            ])

        #expect(live.spans == [10..<20, 50..<100])
        #expect(live.total == 60)
    }

    @Test("starts out not listening, and ignores a repeated state")
    func startsMuted() {
        let live = MicrophoneLive(
            duration: 30,
            transitions: [
                Transition(at: 0, live: false), Transition(at: 5, live: true),
                Transition(at: 6, live: true), Transition(at: 9, live: false),
                Transition(at: 9, live: false),
            ])

        #expect(live.spans == [5..<9])
    }

    @Test("has nothing to say when the call listened throughout")
    func noNote() {
        #expect(MicrophoneLive(duration: 60, spans: [0..<60]).note == nil)
        #expect(MicrophoneLive(duration: 60, spans: [0..<30]).note != nil)
    }

    @Test("says the muted time on a clock")
    func clock() {
        #expect(MicrophoneLive.clock(290.2) == "4:50")
        #expect(MicrophoneLive.clock(3_600) == "1:00:00")
        #expect(MicrophoneLive.clock(0.4) == "0:00")
    }

    @Test("comes back from disk as it went")
    func roundTrip() throws {
        let url = URL(filePath: NSTemporaryDirectory())
            .appendingPathComponent("anyrec-live-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let live = MicrophoneLive(duration: 290.25, spans: [1.5..<12, 40..<290.25])

        try live.write(to: url)

        #expect(MicrophoneLive.read(url) == live)
        #expect(MicrophoneLive.read(url.appendingPathExtension("missing")) == nil)
    }
}
