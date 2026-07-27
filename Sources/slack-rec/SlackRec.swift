import ArgumentParser
import SlackRecKit

extension VideoCodec: ExpressibleByArgument {}
extension TranscriptionEngine: ExpressibleByArgument {}

@main
struct SlackRec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slack-rec",
        abstract: "Record a call — window video, system audio and microphone — as separate tracks.",
        discussion: """
        Run `slack-rec` on its own for the interactive picker. It lists windows — call \
        apps' first — and displays; `slack-rec record` takes the same choice as \
        --window or --display.

        Everyone on the call must know they are being recorded. In the EU that is not \
        a courtesy, it is the law: say it out loud or post it in the channel before \
        you start.
        """,
        version: "0.2.2",
        subcommands: [Tui.self, Record.self, Transcribe.self, Sources.self, Doctor.self],
        defaultSubcommand: Tui.self
    )
}
