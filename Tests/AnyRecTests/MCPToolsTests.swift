import AnyRecKit
import Foundation
import MCP
import Testing
@testable import anyrec

@Suite("MCP tools")
struct MCPToolsTests {
    @Test("Only the six read-only tools are advertised")
    func definitions() {
        #expect(Set(MCPTools.definitions.map(\.name)) == [
            "list_meetings", "search_meetings", "get_meeting", "get_transcript", "get_summary", "get_participants",
        ])
        for tool in MCPTools.definitions {
            #expect(tool.annotations.readOnlyHint == true)
            #expect(tool.annotations.destructiveHint == false)
            #expect(tool.annotations.openWorldHint == false)
            #expect(tool.inputSchema.objectValue?["additionalProperties"] == .bool(false))
        }
    }

    @Test("Invalid arguments become tool errors and unknown tools are protocol errors")
    func validation() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try MeetingReader(root: root)
        let calls: [(String, [String: Value])] = [
            ("get_meeting", [:]), ("get_meeting", ["meeting_id": "../outside"]),
            ("list_meetings", ["path": "/tmp"]), ("list_meetings", ["limit": true]),
            ("list_meetings", ["limit": 101]), ("list_meetings", ["offset": -1]),
            ("search_meetings", ["query": " "]), ("search_meetings", ["query": "test", "scope": "files"]),
            ("list_meetings", ["after": "yesterday"]),
            ("list_meetings", ["after": "2026-11-02T00:00:00Z", "before": "2026-11-01T00:00:00Z"]),
        ]
        for (name, args) in calls { #expect(try MCPTools.call(name, arguments: args, reader: reader).isError == true) }
        #expect(throws: MCPError.self) { try MCPTools.call("delete_meeting", arguments: [:], reader: reader) }
    }

    @Test("Tools return matching structured and text JSON with ISO dates")
    func output() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("rec-2026-11-01-120000")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try RecordingInfo(title: "Example", bundleID: nil, width: 1, height: 1, fps: 1).write(to: directory)
        let reader = try MeetingReader(root: root)
        let result = try MCPTools.call("get_meeting", arguments: ["meeting_id": .string(directory.lastPathComponent)], reader: reader)
        #expect(result.isError == false)
        guard case .text(let text, _, _) = result.content.first else { Issue.record("Missing JSON text"); return }
        #expect(try JSONDecoder().decode(Value.self, from: Data(text.utf8)) == result.structuredContent)
        let started = try #require(result.structuredContent?.objectValue?["startedAt"]?.stringValue)
        #expect(ISO8601DateFormatter().date(from: started) != nil)
        let summary = try MCPTools.call("get_summary", arguments: ["meeting_id": .string(directory.lastPathComponent)], reader: reader)
        #expect(summary.isError == false)
        #expect(summary.structuredContent?.objectValue?["summary"] == nil)
    }

    @Test("MCP command parses a custom root without launching the recording UI")
    func command() throws {
        let parsed = try AnyRec.parseAsRoot(["mcp", "--recordings", "/tmp/library"])
        let command = try #require(parsed as? MCPCommand)
        #expect(command.recordings == "/tmp/library")
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-mcp-tools-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
