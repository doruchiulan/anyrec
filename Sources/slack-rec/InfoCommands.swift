import ArgumentParser
import Foundation
import SlackRecKit

struct Windows: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List capturable windows, Slack's by default."
    )

    @Flag(name: .long, help: "List every application's windows, not just Slack's.")
    var all = false

    func run() async throws {
        try Permissions.requireScreenRecording()
        let windows = try await ContentInventory.windows(
            bundleID: all ? nil : CaptureTarget.slackBundleID
        )
        guard !windows.isEmpty else {
            print("No windows found. Is Slack open?")
            return
        }
        for window in windows {
            let size = "\(window.width)×\(window.height)"
                .padding(toLength: 12, withPad: " ", startingAt: 0)
            let id = String(window.id).padding(toLength: 8, withPad: " ", startingAt: 0)
            print("\(id)\(size)\(window.application) — \(window.title)")
        }
    }
}

struct Displays: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List capturable displays.")

    func run() async throws {
        try Permissions.requireScreenRecording()
        for display in try await ContentInventory.displays() {
            print("\(display.index)  \(display.width)×\(display.height)  id \(display.id)")
        }
    }
}

struct Mics: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List microphone input devices.")

    func run() async throws {
        let devices = AudioDevices.inputs()
        guard !devices.isEmpty else {
            print("No audio input devices found.")
            return
        }
        for device in devices {
            print("\(device.isDefault ? "*" : " ") \(device.name)\n    \(device.id)")
        }
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check permissions and dependencies before a real call."
    )

    func run() async throws {
        for (permission, granted) in Permissions.status(needsMicrophone: true) {
            print("\(mark(granted)) \(permission.rawValue)")
            if !granted { print("    \(permission.settingsURL.absoluteString)") }
        }

        if let ffmpeg = Muxer.ffmpegPath() {
            print("\(mark(true)) ffmpeg at \(ffmpeg)")
        } else {
            print("\(mark(false)) ffmpeg not found — no call.mp4 will be produced")
            print("    brew install ffmpeg")
        }

        guard Permissions.screenRecordingGranted() else { return }
        let running = try await ContentInventory.isRunning(bundleID: CaptureTarget.slackBundleID)
        print("\(mark(running)) Slack \(running ? "is running" : "is not running")")
    }

    private func mark(_ ok: Bool) -> String { ok ? "ok  " : "MISSING" }
}
