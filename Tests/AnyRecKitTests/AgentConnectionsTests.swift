import Foundation
import Testing
@testable import AnyRecKit

@Suite("AI app connections")
struct AgentConnectionsTests {
    let launch = MCPLaunch.serving("/Users/me/Desktop/AnyRec Recordings", with: "/Applications/AnyRec.app/Contents/MacOS/AnyRec")

    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func connections(_ home: URL, claude: [String] = []) -> AgentConnections {
        AgentConnections(home: home, applications: [], claudeLocations: claude)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test("Codex: the table is added at the end and everything else is kept as written")
    func codexAdds() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".codex/config.toml")
        let original = "model = \"gpt-5\" # mine\n\n[mcp_servers.other]\ncommand = \"x\"\n"
        try write(original, to: file)
        let agents = connections(home)
        #expect(agents.state(of: .codex, for: launch) == .notConnected)
        try agents.connect(.codex, to: launch)
        let text = try read(file)
        #expect(text.hasPrefix(original))
        #expect(text.contains("[mcp_servers.anyrec]\ncommand = \"/Applications/AnyRec.app/Contents/MacOS/AnyRec\"\nargs = [\"mcp\", \"--recordings\", \"/Users/me/Desktop/AnyRec Recordings\"]\n"))
        #expect(agents.state(of: .codex, for: launch) == .connected)
    }

    @Test("Codex: an existing entry is replaced in place, its subtables with it, and the next table's comment stays")
    func codexReplaces() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".codex/config.toml")
        try write("""
        a = 1

        [mcp_servers.anyrec]
        command = "/dev/anyrec"
        args = [
          "mcp", # the server
        ]

        [mcp_servers.anyrec.env]
        X = "1"

        # notices
        [notice]
        b = 2
        """, to: file)
        let agents = connections(home)
        #expect(agents.state(of: .codex, for: launch) == .connectedElsewhere(MCPLaunch(command: "/dev/anyrec", arguments: ["mcp"])))
        try agents.connect(.codex, to: launch)
        let text = try read(file)
        #expect(text.hasPrefix("a = 1\n\n[mcp_servers.anyrec]\ncommand = \"/Applications"))
        #expect(!text.contains("/dev/anyrec"))
        #expect(!text.contains("X = \"1\""))
        #expect(text.contains("# notices\n[notice]\nb = 2"))
        #expect(agents.state(of: .codex, for: launch) == .connected)

        try agents.disconnect(.codex)
        #expect(try read(file) == "a = 1\n\n# notices\n[notice]\nb = 2")
        #expect(agents.state(of: .codex, for: launch) == .notConnected)
    }

    @Test("Codex: quoted headers and escapes are read; an inline entry is left to its author")
    func codexForms() throws {
        #expect(CodexConfig.entry(in: "[ mcp_servers.\"anyrec\" ] # x\ncommand = 'C:\\path'\nargs = [\"a\\\"b\", 'c']")
            == .found(MCPLaunch(command: "C:\\path", arguments: ["a\"b", "c"])))
        #expect(CodexConfig.entry(in: "[mcp_servers]\nanyrec = { command = \"x\" }") == .inline)
        #expect(CodexConfig.entry(in: "mcp_servers.anyrec.command = \"x\"") == .inline)
        #expect(CodexConfig.entry(in: "[mcp_servers.anyrecord]\ncommand = \"x\"") == .none)
        #expect(CodexConfig.quoted("a\"b\\c\n") == "\"a\\\"b\\\\c\\n\"")

        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".codex/config.toml")
        try write("[mcp_servers]\nanyrec = { command = \"x\" }\n", to: file)
        #expect(throws: AgentConnectionError.inlineEntry(file)) { try connections(home).connect(.codex, to: launch) }
        #expect(try read(file) == "[mcp_servers]\nanyrec = { command = \"x\" }\n")
    }

    @Test("Codex counts as installed with the ChatGPT app and no config yet, and the file is created")
    func codexCreates() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let applications = home.appendingPathComponent("Applications")
        let agents = AgentConnections(home: home, applications: [applications], claudeLocations: [])
        #expect(agents.state(of: .codex, for: launch) == .notInstalled)
        try FileManager.default.createDirectory(at: applications.appendingPathComponent("ChatGPT.app"), withIntermediateDirectories: true)
        #expect(agents.state(of: .codex, for: launch) == .notConnected)
        try agents.connect(.codex, to: launch)
        #expect(try read(home.appendingPathComponent(".codex/config.toml")).hasPrefix("[mcp_servers.anyrec]\n"))
    }

    @Test("Claude Desktop: the entry is written beside the other settings and removed again")
    func claudeDesktop() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let agents = connections(home)
        #expect(agents.state(of: .claudeDesktop, for: launch) == .notInstalled)
        let file = agents.settingsFile(of: .claudeDesktop)
        try write(#"{"mcpServers":{"other":{"command":"y"}},"preferences":{"on":true,"list":["a/b"]}}"#, to: file)
        #expect(agents.state(of: .claudeDesktop, for: launch) == .notConnected)
        try agents.connect(.claudeDesktop, to: launch)
        #expect(agents.state(of: .claudeDesktop, for: launch) == .connected)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let preferences = try #require(root["preferences"] as? [String: Any])
        #expect(preferences["on"] as? Bool == true)
        #expect(preferences["list"] as? [String] == ["a/b"])
        #expect((root["mcpServers"] as? [String: Any])?["other"] != nil)

        try agents.disconnect(.claudeDesktop)
        #expect(agents.state(of: .claudeDesktop, for: launch) == .notConnected)
        #expect(try read(file).contains("\"other\""))
    }

    @Test("A settings file that isn't JSON is reported and never written")
    func unreadable() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let agents = connections(home)
        let file = agents.settingsFile(of: .claudeDesktop)
        try write("{ not json", to: file)
        #expect(agents.state(of: .claudeDesktop, for: launch) == .unreadable(file))
        #expect(throws: AgentConnectionError.unreadable(file)) { try agents.connect(.claudeDesktop, to: launch) }
        #expect(try read(file) == "{ not json")
    }

    @Test("Claude Code is read from ~/.claude.json and changed through claude mcp")
    func claudeCode() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(connections(home).state(of: .claudeCode, for: launch) == .notInstalled)

        /// A stand-in `claude` that logs its arguments and applies add/remove to ~/.claude.json.
        let claude = home.appendingPathComponent("claude")
        try write("""
        #!/bin/sh
        echo "$@" >> "\(home.path)/calls"
        case "$2" in
          add) printf '{"mcpServers":{"anyrec":{"type":"stdio","command":"%s","args":["mcp","--recordings","%s"],"env":{}}}}' "$7" "${10}" > "\(home.path)/.claude.json" ;;
          remove) echo '{"mcpServers":{}}' > "\(home.path)/.claude.json" ;;
        esac
        """, to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let agents = connections(home, claude: [claude.path])
        #expect(agents.state(of: .claudeCode, for: launch) == .notConnected)

        try agents.connect(.claudeCode, to: launch)
        #expect(agents.state(of: .claudeCode, for: launch) == .connected)
        let calls = try read(home.appendingPathComponent("calls")).split(separator: "\n")
        #expect(calls == [
            "mcp remove --scope user anyrec",
            "mcp add --scope user anyrec -- /Applications/AnyRec.app/Contents/MacOS/AnyRec mcp --recordings /Users/me/Desktop/AnyRec Recordings",
        ])
        try agents.disconnect(.claudeCode)
        #expect(agents.state(of: .claudeCode, for: launch) == .notConnected)
    }

    @Test("Other apps get the common mcpServers JSON")
    func json() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(launch.json.utf8)) as? [String: Any])
        let entry = try #require((object["mcpServers"] as? [String: Any])?["anyrec"] as? [String: Any])
        #expect(entry["command"] as? String == launch.command)
        #expect(entry["args"] as? [String] == launch.arguments)
    }
}
