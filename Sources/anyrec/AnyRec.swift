import ArgumentParser
import AnyRecKit

extension VideoCodec: ExpressibleByArgument {}
extension TranscriptionEngine: ExpressibleByArgument {}

@main
struct AnyRec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "anyrec",
        abstract: "Record a call — window video, system audio and microphone — as separate tracks.",
        discussion: """
        Run `anyrec` on its own for the interactive picker. It lists windows — call \
        apps' first — and displays; `anyrec record` takes the same choice as \
        --window or --display.

        Everyone on the call must know they are being recorded. In the EU that is not \
        a courtesy, it is the law: say it out loud or post it in the channel before \
        you start.
        """,
        version: "0.1.0",
        subcommands: [Tui.self, Record.self, Transcribe.self, Sources.self, Doctor.self],
        defaultSubcommand: Tui.self
    )
}
