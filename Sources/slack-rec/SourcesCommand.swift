import ArgumentParser
import Foundation
import SlackRecKit

/// One "what can I point this at?" screen: everything selectable, beside the flag
/// that selects it. Microphones need no screen permission, so they are listed even
/// when nothing else can be.
struct Sources: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources",
        abstract: "List what can be captured, and the flag that selects each one."
    )

    @Flag(name: .long, help: "Every application and window, not just call apps'.")
    var all = false

    func run() async throws {
        var lines = try await capturable()
        lines += microphones()
        lines.append("\n* recognised call app / system default")
        print(lines.joined(separator: "\n"))
    }

    private func capturable() async throws -> [String] {
        guard Permissions.screenRecordingGranted() else {
            return [
                section("Apps, windows and displays"),
                "  Screen Recording is not granted, so there is nothing to list.",
                "  " + Permission.screenRecording.settingsURL.absoluteString,
            ]
        }
        return try await applications() + displays()
    }

    /// Windows nest under the app that owns them: `--bundle-id` composites all of an
    /// app's windows, `--window` follows one, and the choice only makes sense side by side.
    private func applications() async throws -> [String] {
        let head = section("Apps and their windows", "--bundle-id · --window")
        let apps = try await ContentInventory.applications().filter { all || $0.isKnownCallApp }
        guard !apps.isEmpty else {
            return [head, all ? "  Nothing with a capturable window." : noCallApps]
        }
        let windows = Dictionary(grouping: try await ContentInventory.windows(), by: \.bundleID)
        return [head]
            + apps.flatMap { app in
                ["\(app.isKnownCallApp ? "*" : " ") \(pad(app.name, 30))\(app.bundleID)"]
                    + (windows[app.bundleID] ?? []).map(window)
            }
    }

    private func window(_ window: WindowInfo) -> String {
        "      \(pad(String(window.id), 8))\(pad("\(window.width)×\(window.height)", 12))"
            + (window.title.isEmpty ? "—" : window.title)
    }

    private func displays() async throws -> [String] {
        let head = section("Displays", "--display")
        return [head]
            + (try await ContentInventory.displays()).map {
                "  \(pad(String($0.index), 8))\($0.width)×\($0.height)"
            }
    }

    private func microphones() -> [String] {
        let head = section("Microphones", "--mic")
        let devices = AudioDevices.inputs()
        guard !devices.isEmpty else { return [head, "  No input devices."] }
        return [head]
            + devices.flatMap { ["\($0.isDefault ? "*" : " ") \($0.name)", "      \($0.id)"] }
    }

    private var noCallApps: String { "  No call app running. Open one, or pass --all." }

    private func section(_ title: String, _ flag: String = "") -> String {
        flag.isEmpty ? "\n" + title : "\n" + pad(title, 52) + flag
    }

    /// Pads without `padding(toLength:)`, which truncates anything already wider.
    private func pad(_ text: String, _ width: Int) -> String {
        text.count < width ? text + String(repeating: " ", count: width - text.count) : text + " "
    }
}
