import ArgumentParser
import SlackRecKit

extension VideoCodec: ExpressibleByArgument {}

@main
struct SlackRec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slack-rec",
        abstract: "Record a Slack call — window video, system audio and microphone — as separate tracks.",
        discussion: """
        Everyone on the call must know they are being recorded. In the EU that is not \
        a courtesy, it is the law: say it out loud or post it in the channel before \
        you start.
        """,
        version: "0.1.0",
        subcommands: [Record.self, Windows.self, Displays.self, Mics.self, Doctor.self],
        defaultSubcommand: Record.self
    )
}
