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

    private var launch: MCPLaunch {
        MCPLaunch.serving(controller.configuration.outputRoot.expandingTilde,
                          with: Bundle.main.executablePath ?? CommandLine.arguments[0])
    }

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
        .task(id: launch) { await links.refresh(for: launch) }
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
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .accessibilityLabel("Connected")
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
            if let state { Text(Wording.agentDetail(app, state)) }
        }
    }
}

/// The pane's view of `AgentConnections`, read and changed off the main thread: Claude
/// Code is changed by running its `claude` command, which takes a second.
@MainActor
@Observable
final class AgentLinks {
    private(set) var states: [AgentApp: AgentConnection] = [:]
    private(set) var working: AgentApp?
    private(set) var failure: String?
    @ObservationIgnored private let connections = AgentConnections()

    func refresh(for launch: MCPLaunch) async {
        let connections = connections
        states = await Task.detached {
            Dictionary(uniqueKeysWithValues: AgentApp.allCases.map { ($0, connections.state(of: $0, for: launch)) })
        }.value
    }

    func connect(_ app: AgentApp, to launch: MCPLaunch) {
        change(app, launch: launch) { try $0.connect(app, to: launch) }
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
