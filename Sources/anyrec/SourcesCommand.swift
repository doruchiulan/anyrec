import ArgumentParser
import Foundation
import AnyRecKit

/// One "what can I point this at?" screen: everything selectable, beside the flag
/// that selects it. Microphones need no screen permission, so they are listed even
/// when nothing else can be.
struct Sources: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources",
        abstract: "List what can be captured, and the flag that selects each one."
    )

    @Flag(name: .long, help: "Every window, not just call apps'.")
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
                section("Windows and displays"),
                "  Screen Recording is not granted, so there is nothing to list.",
                "  " + Permission.screenRecording.settingsURL.absoluteString,
            ]
        }
        return try await windows() + displays()
    }

    /// Grouped by the app that owns them, because a window id alone says nothing.
    private func windows() async throws -> [String] {
        let head = section("Windows", "--window")
        let found = try await ContentInventory.windows(
            bundleIDs: all ? nil : CallApps.bundleIDs
        )
        guard !found.isEmpty else {
            return [head, all ? "  Nothing with a capturable window." : noCallApps]
        }
        return [head]
            + Dictionary(grouping: found, by: \.bundleID)
            .sorted { rank($0.value[0]) < rank($1.value[0]) }
            .flatMap { _, owned in
                ["\(CallApps.isKnown(owned[0].bundleID) ? "*" : " ") \(owned[0].application)"]
                    + owned.map(window)
            }
    }

    private func rank(_ window: WindowInfo) -> (Int, String) {
        (CallApps.isKnown(window.bundleID) ? 0 : 1, window.application.lowercased())
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

    private var noCallApps: String { "  No call app window open. Open one, or pass --all." }

    private func section(_ title: String, _ flag: String = "") -> String {
        flag.isEmpty ? "\n" + title : "\n" + pad(title, 52) + flag
    }

    /// Pads without `padding(toLength:)`, which truncates anything already wider.
    private func pad(_ text: String, _ width: Int) -> String {
        text.count < width ? text + String(repeating: " ", count: width - text.count) : text + " "
    }
}
