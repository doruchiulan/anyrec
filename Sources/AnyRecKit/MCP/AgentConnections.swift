import Foundation

/// The AI apps AnyRec's MCP server can be connected to from Settings. ChatGPT and Codex
/// are one entry: the ChatGPT app carries Codex inside it, and both read their MCP servers
/// from `~/.codex/config.toml`.
public enum AgentApp: String, CaseIterable, Sendable, Identifiable {
    case claudeCode, claudeDesktop, codex
    public var id: String { rawValue }
}

/// What a client runs to reach the server.
public struct MCPLaunch: Equatable, Sendable {
    public var command: String
    public var arguments: [String]

    public init(command: String, arguments: [String]) {
        self.command = command
        self.arguments = arguments
    }

    /// `executable mcp --recordings root`: the CLI, which serves the folder it is given.
    public static func serving(_ root: String, with executable: String) -> MCPLaunch {
        MCPLaunch(command: executable, arguments: ["mcp", "--recordings", root])
    }

    /// `AnyRec mcp`: the app's own binary, which serves wherever the app keeps its recordings
    /// when it starts. Entries used to name the folder, and went on naming it after the
    /// recordings moved off the Desktop: every connected app then got "Connection closed".
    public static func app(_ executable: String) -> MCPLaunch {
        MCPLaunch(command: executable, arguments: ["mcp"])
    }

    /// The folder `--recordings` names, if any.
    public var recordings: String? {
        guard let flag = arguments.firstIndex(of: "--recordings"), flag + 1 < arguments.count else { return nil }
        return arguments[flag + 1]
    }

    /// Runs what `launch`, the app's own, runs: the same binary serving `library`, either
    /// named outright or because the folder it names is gone (`MCPTools.root`).
    public func serves(like launch: MCPLaunch, library: String, exists: (String) -> Bool) -> Bool {
        guard self != launch else { return true }
        guard command == launch.command, arguments.first == "mcp", launch.arguments == ["mcp"] else { return false }
        guard let folder = recordings else { return arguments == ["mcp"] }
        return arguments == ["mcp", "--recordings", folder]
            && (folder.expandingTilde == library.expandingTilde || !exists(folder.expandingTilde))
    }

    /// The `mcpServers` shape most clients take, for pasting into ones not listed.
    public var json: String {
        let object: [String: Any] = ["mcpServers": ["anyrec": ["command": command, "args": arguments]]]
        let data = (try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Where one app stands with AnyRec.
public enum AgentConnection: Equatable, Sendable {
    case notInstalled
    case notConnected
    /// Its `anyrec` entry runs exactly the launch asked about.
    case connected
    /// It has an `anyrec` entry that runs something else: another copy, the CLI, a moved app.
    /// Nil when the entry could not be read as a command.
    case connectedElsewhere(MCPLaunch?)
    /// Its settings file could not be read. Nothing will write to it.
    case unreadable(URL)
}

public enum AgentConnectionError: LocalizedError, Equatable {
    case notInstalled(AgentApp)
    case unreadable(URL)
    /// An `anyrec` entry written inline (`anyrec = { … }`), which is left to its author.
    case inlineEntry(URL)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let app): "\(app.rawValue) is not installed."
        case .unreadable(let url): "Couldn't read \(url.path); it was left as it is."
        case .inlineEntry(let url): "\(url.path) sets anyrec up inline; change it there by hand."
        case .commandFailed(let output): output
        }
    }
}

/// Reads and writes the one `anyrec` entry each app keeps, leaving everything else in its
/// file as it was. Claude Code is changed through its own `claude mcp`, because running
/// sessions rewrite `~/.claude.json` all the time and a second writer would lose one side's
/// change; it is read directly. Claude Desktop's JSON and Codex's TOML are edited here.
public struct AgentConnections: Sendable {
    public let home: URL
    /// Folders the apps are looked for in.
    public let applications: [URL]
    /// Where `claude` is looked for. A GUI app's PATH holds none of them.
    public let claudeLocations: [String]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applications: [URL]? = nil, claudeLocations: [String]? = nil
    ) {
        self.home = home
        self.applications = applications ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        self.claudeLocations = claudeLocations ?? [
            home.appendingPathComponent(".local/bin/claude").path,
            home.appendingPathComponent(".claude/local/claude").path,
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            home.appendingPathComponent(".npm-global/bin/claude").path,
            home.appendingPathComponent(".bun/bin/claude").path,
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
    }

    public func settingsFile(of app: AgentApp) -> URL {
        switch app {
        case .claudeCode: home.appendingPathComponent(".claude.json")
        case .claudeDesktop: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .codex: home.appendingPathComponent(".codex/config.toml")
        }
    }

    public func isInstalled(_ app: AgentApp) -> Bool {
        let fileManager = FileManager.default
        switch app {
        case .claudeCode:
            return claude != nil
        case .claudeDesktop:
            return fileManager.fileExists(atPath: settingsFile(of: app).deletingLastPathComponent().path)
                || hasApp("Claude.app")
        case .codex:
            return fileManager.fileExists(atPath: home.appendingPathComponent(".codex").path)
                || hasApp("ChatGPT.app") || hasApp("Codex.app")
        }
    }

    /// `library`, for the app's own launch: an older entry of the same binary that still
    /// serves it counts as connected (`MCPLaunch.serves(like:library:exists:)`).
    public func state(of app: AgentApp, for launch: MCPLaunch, library: String? = nil) -> AgentConnection {
        let file = settingsFile(of: app)
        let entry: Entry
        do { entry = try self.entry(of: app) } catch { return .unreadable(file) }
        switch entry {
        case .none: return isInstalled(app) ? .notConnected : .notInstalled
        case .found(let found):
            guard let found else { return .connectedElsewhere(nil) }
            let same = library.map { found.serves(like: launch, library: $0, exists: Self.isDirectory) } ?? (found == launch)
            return same ? .connected : .connectedElsewhere(found)
        case .inline: return .connectedElsewhere(nil)
        }
    }

    public static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// Points `app` at `launch`, replacing any `anyrec` entry it had.
    public func connect(_ app: AgentApp, to launch: MCPLaunch) throws {
        guard isInstalled(app) else { throw AgentConnectionError.notInstalled(app) }
        switch app {
        case .claudeCode:
            _ = try? runClaude(["mcp", "remove", "--scope", "user", "anyrec"])
            try runClaude(["mcp", "add", "--scope", "user", "anyrec", "--", launch.command] + launch.arguments)
        case .claudeDesktop:
            try editJSON(settingsFile(of: app)) { servers in
                servers["anyrec"] = ["command": launch.command, "args": launch.arguments]
            }
        case .codex:
            try editTOML(launch)
        }
    }

    public func disconnect(_ app: AgentApp) throws {
        switch app {
        case .claudeCode:
            guard claude != nil else { throw AgentConnectionError.notInstalled(app) }
            try runClaude(["mcp", "remove", "--scope", "user", "anyrec"])
        case .claudeDesktop:
            guard FileManager.default.fileExists(atPath: settingsFile(of: app).path) else { return }
            try editJSON(settingsFile(of: app)) { servers in servers["anyrec"] = nil }
        case .codex:
            guard FileManager.default.fileExists(atPath: settingsFile(of: app).path) else { return }
            try editTOML(nil)
        }
    }

    // MARK: Reading

    enum Entry: Equatable {
        case none
        case found(MCPLaunch?)
        case inline
    }

    func entry(of app: AgentApp) throws -> Entry {
        let file = settingsFile(of: app)
        guard let data = FileManager.default.contents(atPath: file.path) else { return .none }
        switch app {
        case .claudeCode, .claudeDesktop:
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentConnectionError.unreadable(file)
            }
            guard let entry = (root["mcpServers"] as? [String: Any])?["anyrec"] else { return .none }
            guard let server = entry as? [String: Any], let command = server["command"] as? String else {
                return .found(nil)
            }
            return .found(MCPLaunch(command: command, arguments: server["args"] as? [String] ?? []))
        case .codex:
            guard let text = String(data: data, encoding: .utf8) else { throw AgentConnectionError.unreadable(file) }
            return CodexConfig.entry(in: text)
        }
    }

    // MARK: Writing

    private var claude: String? {
        claudeLocations.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private func runClaude(_ arguments: [String]) throws -> Shell.Result {
        guard let claude else { throw AgentConnectionError.notInstalled(.claudeCode) }
        /// A Claude Code installed through npm is a node script: node has to be on the path.
        let path = ([URL(fileURLWithPath: claude).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
            + [ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        let result = try Shell.run(claude, arguments, directory: home, environment: ["PATH": path])
        guard result.succeeded else {
            throw AgentConnectionError.commandFailed(result.combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    private func editJSON(_ file: URL, _ change: (inout [String: Any]) -> Void) throws {
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: file.path), !data.isEmpty {
            guard let read = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentConnectionError.unreadable(file)
            }
            root = read
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        change(&servers)
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    private func editTOML(_ launch: MCPLaunch?) throws {
        let file = settingsFile(of: .codex)
        var text = ""
        if let data = FileManager.default.contents(atPath: file.path) {
            guard let read = String(data: data, encoding: .utf8) else { throw AgentConnectionError.unreadable(file) }
            text = read
        }
        guard CodexConfig.entry(in: text) != .inline else { throw AgentConnectionError.inlineEntry(file) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(CodexConfig.setting(launch, in: text).utf8).write(to: file, options: .atomic)
    }

    private func hasApp(_ name: String) -> Bool {
        applications.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) }
    }
}

/// Just enough TOML for the `[mcp_servers.anyrec]` table of Codex's `config.toml`: find it,
/// read its `command` and `args`, and replace or remove it and its subtables, every other
/// line kept as written. Not a TOML parser; the rest of the file is never interpreted.
enum CodexConfig {
    static func entry(in text: String) -> AgentConnections.Entry {
        let lines = text.components(separatedBy: "\n")
        var table = ""
        for line in lines {
            if let header = header(line) {
                table = header
                continue
            }
            if let key = key(line),
               (table == "mcp_servers" && (key == "anyrec" || key.hasPrefix("anyrec.")))
                || (table.isEmpty && key.hasPrefix("mcp_servers.anyrec")) {
                return .inline
            }
        }
        guard let block = blocks(in: lines).first(where: { header(lines[$0.lowerBound]) == "mcp_servers.anyrec" }) else {
            return .none
        }
        let body = lines[block].dropFirst().joined(separator: "\n")
        guard let command = value(of: "command", in: body).flatMap({ $0 as? String }) else { return .found(nil) }
        let arguments = value(of: "args", in: body).flatMap { $0 as? [String] } ?? []
        return .found(MCPLaunch(command: command, arguments: arguments))
    }

    /// `text` with the anyrec tables replaced by one for `launch` (where the first of them
    /// was, else at the end), or removed when `launch` is nil.
    static func setting(_ launch: MCPLaunch?, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let found = blocks(in: lines)
        let position = found.first?.lowerBound
        for block in found.reversed() { lines.removeSubrange(block) }
        guard let launch else { return lines.joined(separator: "\n") }
        let table = [
            "[mcp_servers.anyrec]",
            "command = \(quoted(launch.command))",
            "args = [\(launch.arguments.map(quoted).joined(separator: ", "))]",
        ]
        if let position {
            let spaced = position < lines.count && !lines[position].trimmingCharacters(in: .whitespaces).isEmpty
            lines.insert(contentsOf: table + (spaced ? [""] : []), at: position)
        } else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines += (lines.isEmpty ? [] : [""]) + table + [""]
        }
        return lines.joined(separator: "\n")
    }

    /// The line ranges of `[mcp_servers.anyrec]` and its subtables, each from its header to
    /// the next header, less the comments and blank lines right above that header, which
    /// belong to the table after.
    private static func blocks(in lines: [String]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0
        while index < lines.count {
            guard let name = header(lines[index]), name == "mcp_servers.anyrec" || name.hasPrefix("mcp_servers.anyrec.") else {
                index += 1
                continue
            }
            var end = index + 1
            while end < lines.count, header(lines[end]) == nil, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[[") {
                end += 1
            }
            if end < lines.count {
                while end > index + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") { end -= 1 }
            }
            ranges.append(index..<end)
            index = end
        }
        return ranges
    }

    /// `mcp_servers.anyrec` from `[mcp_servers.anyrec]` or `[ mcp_servers."anyrec" ] # note`;
    /// nil for anything that is not a table header, array tables included.
    static func header(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[["), let close = trimmed.firstIndex(of: "]") else { return nil }
        return normalised(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
    }

    /// The key of a `key = value` line, dotted keys normalised like headers.
    private static func key(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("["), let equals = trimmed.firstIndex(of: "=") else { return nil }
        return normalised(trimmed[..<equals])
    }

    private static func normalised(_ name: Substring) -> String {
        name.split(separator: ".").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }.joined(separator: ".")
    }

    /// The value of `key = …` in a table body: a string or an array of strings.
    private static func value(of key: String, in body: String) -> Any? {
        let lines = body.components(separatedBy: "\n")
        guard let line = lines.firstIndex(where: { self.key($0) == key }) else { return nil }
        let rest = lines[line...].joined(separator: "\n")
        var scanner = Scanner(Array(rest.drop { $0 != "=" }.dropFirst()))
        return scanner.value()
    }

    private struct Scanner {
        let characters: [Character]
        var index = 0

        init(_ characters: [Character]) { self.characters = characters }

        mutating func value() -> Any? {
            skip()
            guard index < characters.count else { return nil }
            switch characters[index] {
            case "\"", "'": return string()
            case "[":
                index += 1
                var items: [String] = []
                while true {
                    skip()
                    guard index < characters.count else { return nil }
                    if characters[index] == "]" { return items }
                    guard let item = string() else { return nil }
                    items.append(item)
                    skip()
                    if index < characters.count, characters[index] == "," { index += 1 }
                }
            default: return nil
            }
        }

        /// Whitespace, newlines and comments between values.
        private mutating func skip() {
            while index < characters.count {
                if characters[index].isWhitespace { index += 1 } else if characters[index] == "#" {
                    while index < characters.count, characters[index] != "\n" { index += 1 }
                } else { return }
            }
        }

        private mutating func string() -> String? {
            let quote = characters[index]
            index += 1
            var text = ""
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == quote { return text }
                guard quote == "\"", character == "\\", index < characters.count else {
                    text.append(character)
                    continue
                }
                let escape = characters[index]
                index += 1
                switch escape {
                case "n": text.append("\n")
                case "t": text.append("\t")
                case "r": text.append("\r")
                case "u", "U":
                    let length = escape == "u" ? 4 : 8
                    guard index + length <= characters.count,
                          let code = UInt32(String(characters[index..<index + length]), radix: 16),
                          let scalar = Unicode.Scalar(code) else { return nil }
                    text.unicodeScalars.append(scalar)
                    index += length
                default: text.append(escape)
                }
            }
            return nil
        }
    }

    /// A TOML basic string.
    static func quoted(_ value: String) -> String {
        var text = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": text += "\\\\"
            case "\"": text += "\\\""
            case "\n": text += "\\n"
            case "\t": text += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                text += String(format: "\\u%04X", scalar.value)
            default: text.unicodeScalars.append(scalar)
            }
        }
        return text + "\""
    }
}
