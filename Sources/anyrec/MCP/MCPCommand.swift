import AnyRecKit
import ArgumentParser
import Foundation

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp",
        abstract: "Read and search the recording library through a local, read-only MCP server over stdio.")

    @Option(name: .long, help: "The recordings folder agents may read.")
    var recordings: String = Defaults.outputRoot

    func run() async throws {
        /// A client that has gone away leaves a closed pipe; writing to it is an error, not the end.
        signal(SIGPIPE, SIG_IGN)
        let root = URL(fileURLWithPath: (recordings as NSString).expandingTildeInPath)
        try await MCPTools.serve(root: root, version: AnyRec.configuration.version)
    }
}
