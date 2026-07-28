import Foundation
import Testing

@testable import AnyRecKit

@Suite("SpeakerBleed")
struct SpeakerBleedTests {
    private let loud = 900.0
    private let room = 20.0

    /// A call is mostly silence: the far end speaks in bursts, you answer in bursts,
    /// and nobody talks the rest of the time.
    private func conversation() -> (system: [Double], mic: [Double]) {
        var system: [Double] = []
        var mic: [Double] = []
        for frame in 0..<200 {
            let callTurn = (30..<60).contains(frame)
            let myTurn = (90..<130).contains(frame)
            system.append(callTurn ? loud : room)
            mic.append(myTurn ? loud : room)
        }
        return (system, mic)
    }

    @Test("headphones: the microphone goes quiet while the call speaks")
    func headphones() {
        let (system, mic) = conversation()

        #expect(SpeakerBleed.excess(system, mic) < 0)
    }

    @Test("speakers: the call comes back through the microphone")
    func speakerBleed() {
        let (system, mic) = conversation()
        let bleeding = zip(system, mic).map { max($1, $0 * 0.4) }

        #expect(SpeakerBleed.excess(system, bleeding) >= SpeakerBleed.threshold)
    }

    @Test("says nothing when either side is too short to judge")
    func tooShort() {
        #expect(SpeakerBleed.excess([1, 2, 3], [1, 2, 3]) == 0)
    }

    @Test("says nothing when the call never speaks")
    func silentCall() {
        let mic = Array(repeating: loud, count: 200)

        #expect(SpeakerBleed.excess(Array(repeating: 0, count: 200), mic) == 0)
    }
}
