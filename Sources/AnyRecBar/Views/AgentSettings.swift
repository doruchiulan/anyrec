import AnyRecKit
import AppKit
import SwiftUI

/// Settings › AI Apps: connect Claude Code, Claude Desktop, and ChatGPT and Codex to the
/// recordings through AnyRec's read-only MCP server. Each is pointed at this app's own
/// binary (`AnyRec mcp`), so nothing else has to be installed. What each app's settings
/// say is read again whenever the pane appears, because people edit them by hand too.
struct AgentSettings: View {
    @Bindable var controller: RecordingController
    @State private var links = AgentLinks()
    @State private var copied = false

    /// No folder in it: the binary serves wherever the library is when it starts, so a
    /// move in Settings › Recording › Storage leaves every connection working.
    private var launch: MCPLaunch {
        MCPLaunch.app(Bundle.main.executablePath ?? CommandLine.arguments[0])
    }

    private var library: String { controller.configuration.outputRoot.expandingTilde }

    /// Run from the download folder, macOS starts the app from a random temporary path,
    /// which would stop working the next time.
    private var translocated: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }

    var body: some View {
        SettingsPane {
            Section {
                ForEach(AgentApp.allCases) { app in
                    row(app)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if translocated { Notice(Wording.agentsTranslocated, level: .error) }
                    if let failure = links.failure { Notice(failure, level: .error) }
                    Text(Wording.agentsFooter).settingsFooter()
                }
            }
            Section {
                LabeledContent {
                    Button(copied ? "Copied" : "Copy Configuration") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(launch.json, forType: .string)
                        copied = true
                    }
                    .disabled(translocated)
                } label: {
                    Text("Other apps")
                    Text("The MCP server entry most apps take, as JSON.")
                }
            }
        }
        .task(id: [launch.command, library]) { await links.refresh(for: launch, library: library) }
    }

    @ViewBuilder
    private func row(_ app: AgentApp) -> some View {
        let state = links.states[app]
        LabeledContent {
            if links.working == app {
                ProgressView().controlSize(.small)
            } else {
                switch state {
                case .notConnected:
                    Button("Connect") { links.connect(app, to: launch) }.disabled(translocated)
                case .connected:
                    HStack {
                        if links.stale.contains(app) {
                            Button(Wording.agentRestart(app)) { links.restart(app, launch: launch) }
                        } else {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityLabel("Connected")
                        }
                        Button("Disconnect") { links.disconnect(app, launch: launch) }
                    }
                case .connectedElsewhere:
                    HStack {
                        Button("Disconnect") { links.disconnect(app, launch: launch) }
                        Button("Use This App") { links.connect(app, to: launch) }.disabled(translocated)
                    }
                case .notInstalled, .unreadable, nil:
                    EmptyView()
                }
            }
        } label: {
            Text(Wording.agentName(app))
            if let state { Text(Wording.agentDetail(app, state, stale: links.stale.contains(app))) }
        }
    }
}

/// The pane's view of `AgentConnections`, read and changed off the main thread: Claude
/// Code is changed by running its `claude` command, which takes a second.
@MainActor
@Observable
final class AgentLinks {
    private(set) var states: [AgentApp: AgentConnection] = [:]
    /// Connected apps that were already running when their settings changed. Claude Desktop
    /// and ChatGPT read MCP servers only at launch; Claude Code starts each session afresh.
    private(set) var stale: Set<AgentApp> = []
    private(set) var working: AgentApp?
    private(set) var failure: String?
    @ObservationIgnored private let connections = AgentConnections()
    /// Where the recordings are: an older entry of this binary that still serves them is connected.
    @ObservationIgnored private var library: String?

    func refresh(for launch: MCPLaunch, library: String? = nil) async {
        if let library { self.library = library }
        let connections = connections, served = self.library
        states = await Task.detached {
            Dictionary(uniqueKeysWithValues: AgentApp.allCases.map { ($0, connections.state(of: $0, for: launch, library: served)) })
        }.value
        stale = Set(AgentApp.allCases.filter { app in
            guard states[app] == .connected, let changed = changed(app) else { return false }
            return Self.running(app).contains { ($0.launchDate ?? .distantFuture) < changed }
        })
    }

    func connect(_ app: AgentApp, to launch: MCPLaunch) {
        change(app, launch: launch) {
            try $0.connect(app, to: launch)
            UserDefaults.standard.set(Date(), forKey: Self.connectedKey(app))
        }
    }

    /// Quits the app, waits for it to go, and opens it again, so it reads its MCP servers.
    func restart(_ app: AgentApp, launch: MCPLaunch) {
        let running = Self.running(app)
        guard working == nil, let bundle = running.first?.bundleURL else { return }
        working = app
        Task {
            running.forEach { $0.terminate() }
            for _ in 0..<100 where running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if running.allSatisfy(\.isTerminated) {
                _ = try? await NSWorkspace.shared.openApplication(at: bundle, configuration: .init())
                failure = nil
            } else {
                failure = "\(Wording.agentName(app)): it didn't quit. Quit it and open it again."
            }
            await refresh(for: launch)
            working = nil
        }
    }

    /// When AnyRec last connected it, else when its settings file last changed.
    private func changed(_ app: AgentApp) -> Date? {
        UserDefaults.standard.object(forKey: Self.connectedKey(app)) as? Date
            ?? (try? FileManager.default.attributesOfItem(atPath: connections.settingsFile(of: app).path)[.modificationDate]) as? Date
    }

    nonisolated private static func connectedKey(_ app: AgentApp) -> String { "agentConnected.\(app.rawValue)" }

    private static func running(_ app: AgentApp) -> [NSRunningApplication] {
        let identifiers: [String] = switch app {
        case .claudeCode: []
        case .claudeDesktop: ["com.anthropic.claudefordesktop"]
        /// The ChatGPT app carries Codex and identifies as it; older ChatGPT builds are com.openai.chat.
        case .codex: ["com.openai.codex", "com.openai.chat"]
        }
        return identifiers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }

    func disconnect(_ app: AgentApp, launch: MCPLaunch) {
        change(app, launch: launch) { try $0.disconnect(app) }
    }

    private func change(_ app: AgentApp, launch: MCPLaunch, _ work: @escaping @Sendable (AgentConnections) throws -> Void) {
        guard working == nil else { return }
        working = app
        failure = nil
        let connections = connections
        Task {
            let error = await Task.detached { () -> String? in
                do { try work(connections); return nil } catch { return error.localizedDescription }
            }.value
            failure = error.map { "\(Wording.agentName(app)): \($0)" }
            await refresh(for: launch)
            working = nil
        }
    }
}
