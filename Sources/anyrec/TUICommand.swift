import ArgumentParser
import Foundation
import AnyRecKit

struct Tui: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tui",
        abstract: "Pick what to record, then watch the levels while it runs."
    )

    @Option(name: .shortAndLong, help: "Directory the recording folder is created in.")
    var output = Defaults.outputRoot

    func run() async throws {
        guard Terminal.isInteractive else {
            var fallback = Record()
            fallback.output = output
            try await fallback.run()
            return
        }
        try await TUISession(settings: Settings(outputRoot: output)).run()
    }
}
