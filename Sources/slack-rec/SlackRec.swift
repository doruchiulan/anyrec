import ArgumentParser
import SlackRecKit

extension VideoCodec: ExpressibleByArgument {}

@main
struct SlackRec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slack-rec",
        abstract: "Record a call — window video, system audio and microphone — as separate tracks.",
        discussion: """
        Run `slack-rec` on its own for the interactive picker. Slack, Teams, Zoom, Meet \
        and the rest are detected automatically; anything else can be captured by \
        window, display or bundle id.

        Everyone on the call must know they are being recorded. In the EU that is not \
        a courtesy, it is the law: say it out loud or post it in the channel before \
        you start.
        """,
        version: "0.2.0",
        subcommands: [
            Tui.self, Record.self, Apps.self, Windows.self, Displays.self, Mics.self,
            Doctor.self,
        ],
        defaultSubcommand: Tui.self
    )
}
