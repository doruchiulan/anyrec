import Foundation
import SlackRecKit

/// The settings screen. Returns the chosen settings, or nil if the user backed out.
struct SetupScreen {
    enum Row: Int, CaseIterable {
        case capture, microphone, systemAudio, stopAfter, mux, transcribe, start

        var label: String {
            switch self {
            case .capture: "Capture"
            case .microphone: "Microphone"
            case .stopAfter: "Stop"
            case .systemAudio: "Call audio"
            case .mux: "Merge"
            case .transcribe: "Transcript"
            case .start: ""
            }
        }
    }

    var settings: Settings
    private var cursor = Row.capture
    private var notice: String?

    init(settings: Settings) {
        self.settings = settings
    }

    mutating func run() async -> Settings? {
        while true {
            Terminal.write(render())
            switch Terminal.readKey() {
            case .up: move(-1)
            case .down, .character("\t"): move(1)
            case .character("k"): move(-1)
            case .character("j"): move(1)
            case .left: adjust(-1)
            case .right: adjust(1)
            case .enter: if await activate() { return settings }
            case .character("r"): return settings
            case .character("q"), .escape, .interrupt: return nil
            default: break
            }
        }
    }

    private mutating func move(_ delta: Int) {
        let all = Row.allCases
        let index = (cursor.rawValue + delta + all.count) % all.count
        cursor = all[index]
    }

    /// Left and right edit in place; only the list-backed rows need a picker.
    private mutating func adjust(_ delta: Int) {
        switch cursor {
        case .systemAudio: settings.systemAudio.toggle()
        case .mux: settings.mux.toggle()
        case .stopAfter: settings.cycleStop(by: delta)
        case .transcribe: settings.cycleTranscribe(by: delta)
        default: break
        }
    }

    /// Returns true when recording should begin.
    private mutating func activate() async -> Bool {
        switch cursor {
        case .capture: await editCapture()
        case .microphone: editMicrophone()
        case .systemAudio, .mux, .stopAfter, .transcribe: adjust(1)
        case .start: return true
        }
        return false
    }

    private mutating func editCapture() async {
        Terminal.write(Terminal.home + "\r\n  " + styled("Looking…", .dim) + Terminal.clearToEnd)
        do {
            let catalogue = try await CaptureCatalogue.load()
            if let picked = Picker.run(
                title: "What should be recorded?",
                items: catalogue.items,
                selected: catalogue.index(of: settings.capture)
            ) {
                settings.capture = catalogue.choices[picked] ?? settings.capture
            }
        } catch {
            notice = "\(error)"
        }
    }

    private mutating func editMicrophone() {
        let devices = AudioDevices.inputs()
        let items =
            devices.map {
                PickerItem(label: $0.name, detail: $0.isDefault ? "system default" : nil)
            } + [PickerItem(label: "Off — do not record my microphone")]

        let current = devices.firstIndex { $0.id == settings.microphone?.id } ?? devices.count
        guard let picked = Picker.run(title: "Microphone", items: items, selected: current)
        else { return }
        settings.microphone = picked < devices.count ? devices[picked] : nil
    }

    private func render() -> String {
        var lines = ["", "  " + styled("slack-rec", .bold, .cyan), ""]

        for row in Row.allCases where row != .start {
            lines.append(line(row))
        }

        lines += ["", startLine(), ""]
        if let warning = warning() { lines += ["  " + styled(warning, .yellow), ""] }
        lines.append("  " + styled("Folder  \(settings.outputRoot)", .dim))
        lines += ["", "  " + styled("↑↓ move   ←→ change   ⏎ open   r record   q quit", .dim)]

        return Terminal.home + lines.map { $0 + Terminal.clearLine }.joined(separator: "\r\n")
            + "\r\n" + Terminal.clearToEnd
    }

    private func line(_ row: Row) -> String {
        let name = row.label.padding(toLength: 12, withPad: " ", startingAt: 0)
        let value = clip(value(row), to: max(20, Terminal.size().columns - 20))
        return cursor == row
            ? "  " + styled("› \(name)\(value)", .bold, .cyan)
            : "    " + styled(name, .dim) + value
    }

    private func value(_ row: Row) -> String {
        switch row {
        case .capture: settings.capture.label
        case .microphone: settings.microphoneLabel
        case .systemAudio: settings.systemAudio ? "On" : "Off"
        case .stopAfter: settings.stopLabel
        case .mux: settings.muxLabel
        case .transcribe: settings.transcribeLabel
        case .start: ""
        }
    }

    private func startLine() -> String {
        let text = "  Start recording  "
        return cursor == .start
            ? "  " + styled(text, .bold, .inverse)
            : "  " + styled(text, .green)
    }

    private func warning() -> String? {
        if let notice { return notice }
        if settings.mux, Muxer.ffmpegPath() == nil {
            return "ffmpeg is missing, so there will be no call.mp4: brew install ffmpeg"
        }
        if settings.transcribe == .whisper, WhisperTranscriber.binaryPath() == nil {
            return "whisper is missing, so there will be no transcript: brew install whisper-cpp"
        }
        if settings.transcribe == .openai, OpenAITranscriber.key() == nil {
            return "No OpenAI key, so there will be no transcript: export OPENAI_API_KEY=…"
        }
        if settings.transcribe == .openai {
            return "OpenAI transcribes off your machine — both audio tracks are uploaded."
        }
        if settings.microphone == nil, !settings.systemAudio {
            return "Both audio tracks are off — this will be a silent video."
        }
        return nil
    }
}
