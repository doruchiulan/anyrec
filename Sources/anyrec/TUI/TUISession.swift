import Foundation
import AnyRecKit

enum TUIError: Error, LocalizedError, CustomStringConvertible {
    case notATerminal

    var description: String {
        switch self {
        case .notATerminal:
            "anyrec needs an interactive terminal for this. Use `anyrec record` instead."
        }
    }

    var errorDescription: String? { description }
}

/// Setup screen → live recording → summary. Raw mode is entered once and always restored.
struct TUISession {
    var configuration: RecordingConfiguration

    func run() async throws {
        guard Terminal.isInteractive else { throw TUIError.notATerminal }
        try Permissions.requireScreenRecording(host: .terminal)

        /// Both of these are slow — the first device enumeration cold-starts
        /// AVFoundation — and must happen before the screen is blanked.
        var prepared = configuration
        prepared.pinDefaultMicrophone()
        let readiness = await Readiness.probe()

        Terminal.enterRawMode()
        defer { Terminal.restore() }

        var screen = SetupScreen(configuration: prepared, readiness: readiness)
        guard var chosen = await screen.run() else { return }

        var notice: String?
        if chosen.microphone != nil, await !Permissions.requestMicrophone() {
            chosen.microphone = nil
            notice = """
                  Microphone access was denied, so this was recorded without it.
                  Grant it at \(Permission.microphone.settingsURL.absoluteString), \
                then quit and reopen your terminal.
                """
        }
        try await record(chosen, notice: notice)
    }

    private func record(_ configuration: RecordingConfiguration, notice: String?) async throws {
        let session = try await RecordingSession.start(configuration)

        var live = RecordingScreen(session: session)
        _ = await live.run()

        let outcome = try await session.stop { stage in
            Terminal.write(
                Terminal.home + "\r\n  " + SummaryReport.status(stage) + Terminal.clearToEnd)
        }

        Terminal.restore()
        print(SummaryReport.render(outcome))
        if let notice { print("\n" + notice) }
        /// Only after raw mode is handed back: the engines print as they go.
        await TranscriptReport.follow(session)
    }
}
