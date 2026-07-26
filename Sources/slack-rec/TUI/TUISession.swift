import Foundation
import SlackRecKit

enum TUIError: Error, CustomStringConvertible {
    case notATerminal

    public var description: String {
        "slack-rec needs an interactive terminal for this. Use `slack-rec record` instead."
    }
}

/// Setup screen → live recording → summary. Raw mode is entered once and always restored.
struct TUISession {
    var settings: Settings

    func run() async throws {
        guard Terminal.isInteractive else { throw TUIError.notATerminal }
        try Permissions.requireScreenRecording()

        /// Cold-starts AVFoundation (seconds) — must happen before the screen is blanked.
        let prepared = withDefaultMicrophone(settings)

        Terminal.enterRawMode()
        defer { Terminal.restore() }

        var screen = SetupScreen(settings: prepared)
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

    private func record(_ settings: Settings, notice: String?) async throws {
        let target = try await TargetResolver.resolve(settings.capture.target)
        let plan = try OutputPlan.create(in: URL(filePath: settings.outputRoot.expandingTilde))
        let recorder = Recorder(options: settings.options, target: target, plan: plan)
        try await recorder.start()

        var live = RecordingScreen(
            recorder: recorder, settings: settings, target: target, plan: plan
        )
        _ = await live.run()

        Terminal.write(Terminal.home + "\r\n  Finishing…" + Terminal.clearToEnd)
        let summary = try await recorder.stop()
        let merged = merge(settings: settings, plan: plan)

        Terminal.restore()
        print(SummaryReport.render(summary, merged: merged))
        if let notice { print("\n" + notice) }
        /// Only after raw mode is handed back: the engines print as they go.
        if let engine = settings.transcribe { await TranscriptRun.follow(plan, engine: engine) }
    }

    private func merge(settings: Settings, plan: OutputPlan) -> MuxOutcome? {
        guard settings.mux, Muxer.ffmpegPath() != nil else { return nil }
        Terminal.write(Terminal.home + "\r\n  Merging with ffmpeg…" + Terminal.clearToEnd)
        return try? Muxer.mux(plan)
    }

    /// The system default is only a starting point; it is pinned as an explicit device so
    /// another app changing the default mid-call cannot redirect the capture.
    private func withDefaultMicrophone(_ settings: Settings) -> Settings {
        guard settings.microphone == nil else { return settings }
        var copy = settings
        let inputs = AudioDevices.inputs()
        copy.microphone = inputs.first(where: \.isDefault) ?? inputs.first
        return copy
    }
}

enum SummaryReport {
    static func render(_ summary: RecordingSummary, merged: MuxOutcome?) -> String {
        var text = Report.render(summary)
        if let merged {
            text += "\n\n  Play this one:  \(merged.output.path)"
            text += merged.notes.map { "\n\n  " + $0 }.joined()
        } else {
            text += "\n\n  screen.mov has no audio track. Install ffmpeg for a combined call.mp4."
        }
        return text
    }
}
