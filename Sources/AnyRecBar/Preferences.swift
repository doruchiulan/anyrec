import AnyRecKit
import Foundation

/// What the panel and the settings window remember between launches. The Kit builds a
/// recording from nothing every time — persisting one is a property of an app that stays
/// open for days, not of a recording — so the mapping to `UserDefaults` lives here, and
/// the terminal is untouched by it.
///
/// The microphone is kept as a device id and resolved against what is actually plugged
/// in, because the device it names may be in a drawer by the next launch.
enum Preferences {
    private static let defaults: UserDefaults = {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.systemAudio: true,
            Key.transcribe: TranscriptionEngine.auto.rawValue,
            Key.offerToRecord: true,
            Key.summarize: true,
            Key.shortcut: true,
            Key.captions: true,
            Key.menuBarExtra: true,
        ])
        return defaults
    }()

    private enum Key {
        static let systemAudio = "systemAudio"
        static let transcribe = "transcribe"
        static let stopAfter = "stopAfterSeconds"
        static let microphone = "microphoneID"
        static let offerToRecord = "offerToRecord"
        static let shortcut = "shortcut"
        static let captions = "captions"
        static let menuBarExtra = "showsMenuBarExtra"
        static let toolbarStrip = "toolbarStrip"
        static let welcomed = "welcomed"
        static let summarize = "summarizeAfterTranscribing"
        static let summaryProvider = "summaryProvider"
        static let summaryLanguage = "summaryLanguage"
    }

    static var transcriptionOptions: TranscriptionOptions {
        get {
            if let data = defaults.data(forKey: "transcriptionOptions"),
               let options = try? JSONDecoder().decode(TranscriptionOptions.self, from: data) { return options }
            var options = TranscriptionOptions()
            if defaults.string(forKey: Key.transcribe) == "openai" { options.enabledEngines.insert(.openai) }
            options.reviewProvider = summaryProvider ?? .claude
            return options
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "transcriptionOptions") }
    }

    /// Whether a call app taking the microphone is worth a notification.
    static var offerToRecord: Bool {
        get { defaults.bool(forKey: Key.offerToRecord) }
        set { defaults.set(newValue, forKey: Key.offerToRecord) }
    }

    /// Setup is complete only after all permissions have been granted.
    static var welcomed: Bool {
        get { defaults.bool(forKey: Key.welcomed) }
        set { defaults.set(newValue, forKey: Key.welcomed) }
    }

    /// The library toolbar's measured spacing, so the first layout of a launch is right.
    static var toolbarStrip: ToolbarStrip.Memory? {
        get {
            guard let data = defaults.data(forKey: Key.toolbarStrip) else { return nil }
            return try? JSONDecoder().decode(ToolbarStrip.Memory.self, from: data)
        }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.toolbarStrip) }
    }

    /// Whether the helper sits in the menu bar. People decide whether an app's extra is
    /// there; the Dock menu and the app's own menus reach everything it does.
    static var menuBarExtra: Bool {
        get { defaults.bool(forKey: Key.menuBarExtra) }
        set { defaults.set(newValue, forKey: Key.menuBarExtra) }
    }

    /// Whether the library's player draws the transcript over the video.
    static var captions: Bool {
        get { defaults.bool(forKey: Key.captions) }
        set { defaults.set(newValue, forKey: Key.captions) }
    }

    static var shortcut: Bool {
        get { defaults.bool(forKey: Key.shortcut) }
        set { defaults.set(newValue, forKey: Key.shortcut) }
    }

    static var summarize: Bool {
        get { defaults.bool(forKey: Key.summarize) }
        set { defaults.set(newValue, forKey: Key.summarize) }
    }

    /// Nil means whichever provider is found first.
    static var summaryProvider: SummaryProvider? {
        get { defaults.string(forKey: Key.summaryProvider).flatMap(SummaryProvider.init) }
        set { defaults.set(newValue?.rawValue, forKey: Key.summaryProvider) }
    }

    /// A language name, or nil to follow the call.
    static var summaryLanguage: String? {
        get { defaults.string(forKey: Key.summaryLanguage) }
        set { defaults.set(newValue, forKey: Key.summaryLanguage) }
    }

    /// "Off" has to survive a relaunch as surely as a choice does, so the transcript
    /// engine is stored as an empty string rather than left absent.
    static func loaded(into configuration: inout RecordingConfiguration) {
        configuration.systemAudio = defaults.bool(forKey: Key.systemAudio)
        configuration.mux = true
        configuration.transcribe = TranscriptionEngine(
            rawValue: defaults.string(forKey: Key.transcribe) ?? "")
        let seconds = defaults.double(forKey: Key.stopAfter)
        configuration.stopAfter = seconds > 0 ? seconds : nil
    }

    /// The microphone is not in here. Everything above is only ever written by someone
    /// changing it; a device is also *resolved*, at launch and whenever the panel opens,
    /// and a resolution that found nothing must not overwrite what was remembered.
    static func save(_ configuration: RecordingConfiguration) {
        defaults.set(configuration.systemAudio, forKey: Key.systemAudio)
        defaults.set(configuration.transcribe?.rawValue ?? "", forKey: Key.transcribe)
        defaults.set(configuration.stopAfter ?? 0, forKey: Key.stopAfter)
    }

    /// Written only when someone picks one, so a headset in a drawer today is still the
    /// headset when it comes back out. Nil is a choice too — it means Off.
    static func saveMicrophone(_ device: AudioInputDevice?) {
        defaults.set(device?.id ?? "", forKey: Key.microphone)
    }

    /// Nil when nothing was remembered, or when what was remembered is not plugged in —
    /// either way the caller falls back to pinning the system default for this run.
    static func microphone(among inputs: [AudioInputDevice]) -> AudioInputDevice? {
        guard let id = defaults.string(forKey: Key.microphone), !id.isEmpty else { return nil }
        return inputs.first { $0.id == id }
    }

    /// True when Off was chosen, as against never having chosen anything — the one case
    /// where not resolving a device is the answer rather than a fallback.
    static var microphoneIsOff: Bool { defaults.string(forKey: Key.microphone) == "" }
}
