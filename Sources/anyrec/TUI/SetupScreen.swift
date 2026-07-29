import Foundation
import AnyRecKit

/// The settings screen. Returns the chosen configuration, or nil if the user backed out.
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

    var configuration: RecordingConfiguration
    let readiness: Readiness
    private var cursor = Row.capture
    private var notice: String?

    init(configuration: RecordingConfiguration, readiness: Readiness) {
        self.configuration = configuration
        self.readiness = readiness
    }

    mutating func run() async -> RecordingConfiguration? {
        while true {
            Terminal.write(render())
            switch Terminal.readKey() {
            case .up: move(-1)
            case .down, .character("\t"): move(1)
            case .character("k"): move(-1)
            case .character("j"): move(1)
            case .left: adjust(-1)
            case .right: adjust(1)
            case .enter: if await activate() { return configuration }
            case .character("r"): if ready() { return configuration }
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
        case .systemAudio: configuration.systemAudio.toggle()
        case .mux: configuration.mux.toggle()
        case .stopAfter: configuration.cycleStop(by: delta)
        case .transcribe: configuration.cycleTranscribe(by: delta)
        default: break
        }
    }

    /// Returns true when recording should begin.
    private mutating func activate() async -> Bool {
        notice = nil
        switch cursor {
        case .capture: await editCapture()
        case .microphone: editMicrophone()
        case .transcribe: await editTranscribe()
        case .systemAudio, .mux, .stopAfter: adjust(1)
        case .start: return ready()
        }
        return false
    }

    /// The one row where ⏎ does something other than cycle: an engine that is not
    /// installed yet has a way to fix that, and cycling past it would only hide it.
    private mutating func editTranscribe() async {
        guard let engine = configuration.transcribe, EngineSetup.opens(engine, readiness) else {
            return adjust(1)
        }
        notice = await EngineSetup.run(for: engine, readiness: readiness)
    }

    private mutating func ready() -> Bool {
        guard configuration.capture == nil else { return true }
        notice = "Pick a window or a display to record first."
        return false
    }

    private mutating func editCapture() async {
        Terminal.write(Terminal.home + "\r\n  " + styled("Looking…", .dim) + Terminal.clearToEnd)
        do {
            let picker = CapturePicker(try await CaptureCatalogue.load())
            if let picked = Picker.run(
                title: "What should be recorded?",
                items: picker.items,
                selected: picker.index(of: configuration.capture)
            ) {
                configuration.capture = picker.choice(at: picked) ?? configuration.capture
                notice = nil
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

        let current = devices.firstIndex { $0.id == configuration.microphone?.id } ?? devices.count
        guard let picked = Picker.run(title: "Microphone", items: items, selected: current)
        else { return }
        configuration.microphone = picked < devices.count ? devices[picked] : nil
    }

    private func render() -> String {
        var lines = ["", "  " + styled("anyrec", .bold, .cyan), ""]

        for row in Row.allCases where row != .start {
            lines.append(line(row))
        }

        lines += ["", startLine(), ""]
        if let warning = warning() { lines += ["  " + styled(warning, .yellow), ""] }
        lines.append("  " + styled("Folder  \(configuration.outputRoot)", .dim))
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
        case .capture: configuration.captureLabel
        case .microphone: configuration.microphoneLabel
        case .systemAudio: configuration.systemAudio ? "On" : "Off"
        case .stopAfter: configuration.stopLabel
        case .mux: configuration.muxLabel
        case .transcribe: configuration.transcribeLabel(readiness)
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
        notice ?? readiness.advisory(for: configuration).map(phrase)
    }
}
