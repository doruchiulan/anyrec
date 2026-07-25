import ArgumentParser
import Foundation
import SlackRecKit

struct Windows: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List capturable windows belonging to call apps."
    )

    @Flag(name: .long, help: "List every application's windows, not just call apps'.")
    var all = false

    @Option(name: .long, help: "List one application's windows.")
    var bundleId: String?

    func run() async throws {
        try Permissions.requireScreenRecording()
        let windows = try await ContentInventory.windows(bundleIDs: filter)
        guard !windows.isEmpty else {
            print(
                all
                    ? "No capturable windows found."
                    : "No call app windows found. Open one, or pass --all."
            )
            return
        }
        for window in windows {
            let size = "\(window.width)×\(window.height)"
                .padding(toLength: 12, withPad: " ", startingAt: 0)
            let id = String(window.id).padding(toLength: 8, withPad: " ", startingAt: 0)
            print("\(id)\(size)\(window.application) — \(window.title)")
        }
    }

    private var filter: Set<String>? {
        if let bundleId { return [bundleId] }
        return all ? nil : CallApps.bundleIDs
    }
}

struct Apps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List applications with capturable windows, call apps first."
    )

    func run() async throws {
        try Permissions.requireScreenRecording()
        for app in try await ContentInventory.applications() {
            let mark = app.isKnownCallApp ? "*" : " "
            let name = app.name.padding(toLength: 26, withPad: " ", startingAt: 0)
            let windows = "\(app.windowCount) window\(app.windowCount == 1 ? "" : "s")"
            print("\(mark) \(name)\(windows.padding(toLength: 12, withPad: " ", startingAt: 0))\(app.bundleID)")
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

        for line in await transcriptionReport() { print(line) }

        guard Permissions.screenRecordingGranted() else { return }
        let apps = try await ContentInventory.runningCallApps()
        if apps.isEmpty {
            print("\(mark(false)) no call app running — open one, or use --display/--window")
        } else {
            print("\(mark(true)) \(apps.map(\.name).joined(separator: ", "))")
        }
    }

    /// Transcription is optional throughout: every line here is informational.
    private func transcriptionReport() async -> [String] {
        var lines: [String] = []

        if #available(macOS 26, *), AppleTranscriber.isAvailable {
            let locales = await AppleTranscriber.supportedLanguages()
            lines.append("\(mark(true)) apple speech, \(locales.count) languages, on-device")
        } else {
            lines.append("\(mark(false)) apple speech needs macOS 26 — whisper covers everything")
        }

        guard let whisper = WhisperTranscriber.binaryPath() else {
            lines.append("\(mark(false)) whisper not found — no Romanian transcripts")
            lines.append("    brew install whisper-cpp")
            return lines
        }
        lines.append("\(mark(true)) whisper at \(whisper)")

        let models = WhisperTranscriber.modelDirectory.path
        guard let model = WhisperTranscriber.defaultModel() else {
            lines.append("\(mark(false)) no whisper model in \(models)")
            lines.append("    download one from https://huggingface.co/ggerganov/whisper.cpp")
            return lines
        }
        lines.append("\(mark(true)) whisper model \(model.lastPathComponent)")
        if WhisperTranscriber.voiceDetectionModel() == nil {
            lines.append("\(mark(false)) no silero VAD model — whisper timestamps will be coarse")
        }
        return lines
    }

    private func mark(_ ok: Bool) -> String { ok ? "ok  " : "MISSING" }
}
