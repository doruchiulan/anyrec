import Testing

@testable import SlackRecKit

@Suite("DurationSpec")
struct DurationSpecTests {
    @Test(
        "parses supported forms",
        arguments: [
            ("90", 90.0), ("90s", 90.0), ("45m", 2_700.0), ("1h", 3_600.0),
            ("1h30m", 5_400.0), ("2h15m30s", 8_130.0), (" 5m ", 300.0), ("1H", 3_600.0),
        ]
    )
    func parses(input: String, expected: Double) throws {
        #expect(try DurationSpec.parse(input) == expected)
    }

    @Test("rejects malformed input", arguments: ["", "abc", "5x", "m", "1h30", "-5", "0"])
    func rejects(input: String) {
        #expect(throws: DurationError.self) { try DurationSpec.parse(input) }
    }
}
