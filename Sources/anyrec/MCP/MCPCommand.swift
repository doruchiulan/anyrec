import AnyRecKit
import ArgumentParser
import Foundation
import MCP

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp",
        abstract: "Read and search the recording library through a local, read-only MCP server over stdio.")

    @Option(name: .long, help: "The recordings folder agents may read.")
    var recordings: String = Defaults.outputRoot

    func run() async throws {
        let root = URL(fileURLWithPath: (recordings as NSString).expandingTildeInPath)
        let reader = try MeetingReader(root: root)
        let server = await MCPTools.server(reader: reader)
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
