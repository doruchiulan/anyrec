import Testing

@testable import SlackRecKit

@Suite("DropRate")
struct DropRateTests {
    @Test("stays quiet about a stray buffer in a long recording")
    func strayBuffer() {
        #expect(DropRate.worthReporting(1, of: 8000) == false)
    }

    @Test("reports a shortfall past half a percent")
    func sustainedShortfall() {
        #expect(DropRate.worthReporting(41, of: 8000))
        #expect(DropRate.worthReporting(40, of: 8000) == false)
    }

    @Test("nothing dropped is never worth reporting")
    func nothingDropped() {
        #expect(DropRate.worthReporting(0, of: 0) == false)
    }

    @Test("drops with nothing captured are always worth reporting")
    func nothingCaptured() {
        #expect(DropRate.worthReporting(1, of: 0))
    }
}
