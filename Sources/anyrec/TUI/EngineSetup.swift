import Foundation
import AnyRecKit

/// What ⏎ on the Transcript row does: install whisper and its model, take an OpenAI
/// key, or — for the engine with nothing to install — say what it can transcribe.
/// Returns a line for the setup screen to show, or nil when nothing needs saying.
enum EngineSetup {
    static func opens(_ engine: TranscriptionEngine, _ readiness: Readiness) -> Bool {
        switch engine {
        /// Apple is the one engine that can be ready and still have no model for the
        /// call, so what it covers is worth reading before the call rather than after.
        case .apple: true
        case .auto: false
        case .whisper, .openai: !readiness.of(engine).isReady
        }
    }

    static func run(for engine: TranscriptionEngine, readiness: Readiness) async -> String? {
        switch engine {
        case .whisper: await installWhisper(readiness)
        case .openai: await saveKey()
        case .apple: showLanguages(readiness.appleLanguages)
        case .auto: nil
        }
    }

    private static func showLanguages(_ languages: [String]) -> String? {
        guard !languages.isEmpty else {
            Page.notice(
                title: "Apple's engine needs macOS 26",
                lines: wrapped(
                    "This Mac cannot run it. whisper transcribes on-device too, in any "
                        + "language — pick it here and ⏎ installs it."))
            return nil
        }
        Page.notice(
            title: "Apple transcribes \(languages.count) languages, on-device",
            lines: wrapped(AppleSpeech.describe(languages)) + [""]
                + wrapped("Anything else needs whisper, or auto, which falls back to it."))
        return nil
    }

    /// A page clips what does not fit rather than wrapping it, and this is the one
    /// thing shown on one that is a sentence rather than a label.
    static func wrapped(_ text: String, to width: Int = max(20, Terminal.size().columns - 10))
        -> [String]
    {
        text.split(separator: " ").reduce(into: [String]()) { lines, word in
            guard let last = lines.last, last.count + word.count < width else {
                return lines.append(String(word))
            }
            lines[lines.count - 1] = last + " " + word
        }
    }

    private static func installWhisper(_ readiness: Readiness) async -> String? {
        guard case .needsSetup(let steps) = readiness.of(.whisper) else { return "whisper is ready." }

        if WhisperSetup.needsHomebrew {
            Page.notice(
                title: "Homebrew is needed first",
                lines: [
                    "whisper is installed with Homebrew, which is not on this machine.",
                    "Install it from https://brew.sh, then come back.",
                ])
            return "Homebrew is needed to install whisper — see https://brew.sh"
        }

        guard
            Page.confirm(
                title: "Set up whisper?",
                lines: steps.map { "  \($0.title)  —  \($0.detail)" } + ["", download(steps)],
                action: "start")
        else { return nil }

        let progress = Progress(steps)
        for (index, step) in steps.enumerated() {
            progress.begin(index)
            do {
                try await WhisperSetup.perform(step) { progress.note(index, $0) }
            } catch {
                Page.notice(title: "\(step.title) failed", lines: ["\(error)"])
                return "whisper is not set up: \(step.title.lowercased()) failed."
            }
        }
        return "whisper is ready."
    }

    private static func download(_ steps: [WhisperSetup.Step]) -> String {
        let bytes = WhisperSetup.downloadSize(of: steps)
        guard bytes > 0 else { return "Nothing large to download." }
        return "About \(AssetDownload.describe(bytes)) to download. It can be left running."
    }

    private static func saveKey() async -> String? {
        var lines = [
            "Make one at https://platform.openai.com/api-keys.",
            "It is saved to \(OpenAIKey.file.path), readable only by you,",
            "and it is never shown, logged, or put in an error.",
        ]
        if OpenAIKey.isFromEnvironment {
            lines.append("")
            lines.append("OPENAI_API_KEY is set in this shell, and takes precedence over the file.")
        }

        guard let key = SecretPrompt.run(title: "OpenAI API key", lines: lines) else { return nil }
        return await store(key)
    }

    private static func store(_ key: String) async -> String {
        Page.working(title: "Checking the key with OpenAI…")
        switch await OpenAIKey.validateAndStore(key) {
        case .saved:
            return "OpenAI key saved."
        case .savedUnverified(let reason):
            return "OpenAI key saved — \(reason)."
        case .savedButShadowed:
            return "Key saved, but OPENAI_API_KEY in this shell is what will be used."
        case .rejected(let complaint), .notSaved(let complaint):
            Page.notice(title: "That key was not saved", lines: ["\(complaint)"])
            return "The OpenAI key was not saved."
        }
    }
}

/// Draws the step list as it advances. The download callback fires hundreds of times,
/// so a redraw only happens when the line it would draw actually changed.
private final class Progress: @unchecked Sendable {
    private let steps: [WhisperSetup.Step]
    private let lock = NSLock()
    private var current = 0
    private var notes: [String]

    init(_ steps: [WhisperSetup.Step]) {
        self.steps = steps
        self.notes = Array(repeating: "", count: steps.count)
    }

    func begin(_ index: Int) {
        lock.lock()
        current = index
        lock.unlock()
        draw()
    }

    func note(_ index: Int, _ text: String) {
        lock.lock()
        let changed = notes[index] != text
        notes[index] = text
        lock.unlock()
        if changed { draw() }
    }

    private func draw() {
        lock.lock()
        let lines = steps.enumerated().map { index, step -> String in
            let note = notes[index]
            if index < current { return styled("  ✓ \(step.title)", .dim) }
            if index > current { return styled("    \(step.title)", .dim) }
            return styled("  › \(step.title)", .bold, .cyan)
                + (note.isEmpty ? "" : styled("  \(note)", .dim))
        }
        lock.unlock()
        Page.working(title: "Setting whisper up…", lines: lines + ["", "This can take a while."])
    }
}
