import Foundation
import Testing
@testable import AnyRecKit

@Suite("Summary timing")
struct SummaryTimingTests {
    @Test("summary receives every timestamp even when all lines have the same speaker")
    func singleSpeaker() async throws {
        let result = try await Summarizer.summary(of: fixture, using: .claude) { _, input, _ in
            #expect(input.split(separator: "\n").count == 3)
            #expect(input.contains("[754.25s] Call: Alex will send the draft."))
            #expect(input.contains("[2410.0s] Call: Sam will schedule the test."))
            return """
            {"overview":"Planning","actions":[
              {"task":"Send the draft","owner":"Alex","at":754.25},
              {"task":"Schedule the test","owner":"Sam","at":2410}]}
            """
        }
        #expect(result.actions.map(\.at) == [754.25, 2410])
    }

    @Test("live summary locates action links to the correct second",
          .enabled(if: ProcessInfo.processInfo.environment["ANYREC_LIVE_SUMMARY_TEST"] == "1"))
    func liveTiming() async throws {
        let summary = try await Summarizer.summary(of: fixture, using: .claude, language: "English")
        #expect(summary.actions.count == 2)
        #expect(Set(summary.actions.compactMap(\.at).map { Int($0) }) == [754, 2410])
    }

    @Test("missing timestamps stay absent and a genuine zero timestamp remains valid")
    func absentTimestamp() throws {
        let result = try #require(Summary.parse("""
        {"overview":"Planning","actions":[
          {"task":"Unlocated action"},{"task":"Opening action","at":0}]}
        """, provider: "test"))
        #expect(result.actions.map(\.at) == [nil, 0])
    }

    private var fixture: Transcript {
        Transcript(utterances: [
            Utterance(start: 0, end: 3, text: "Let’s begin."),
            Utterance(start: 754.25, end: 759, text: "Alex will send the draft."),
            Utterance(start: 2410, end: 2415, text: "Sam will schedule the test."),
        ], language: "en", engine: "reviewed")
    }
}
