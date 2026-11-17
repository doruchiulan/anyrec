import Testing
@testable import anyrec

@Suite("MCP command")
struct MCPCommandTests {
    @Test("MCP command parses a custom root without launching the recording UI")
    func command() throws {
        let parsed = try AnyRec.parseAsRoot(["mcp", "--recordings", "/tmp/library"])
        let command = try #require(parsed as? MCPCommand)
        #expect(command.recordings == "/tmp/library")
    }
}
