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
            Key.mux: true,
            Key.transcribe: TranscriptionEngine.auto.rawValue,
        ])
        return defaults
    }()

    private enum Key {
        static let systemAudio = "systemAudio"
        static let mux = "mux"
        static let transcribe = "transcribe"
        static let stopAfter = "stopAfterSeconds"
        static let microphone = "microphoneID"
    }

    /// "Off" has to survive a relaunch as surely as a choice does, so the transcript
    /// engine is stored as an empty string rather than left absent.
    static func loaded(into configuration: inout RecordingConfiguration) {
        configuration.systemAudio = defaults.bool(forKey: Key.systemAudio)
        configuration.mux = defaults.bool(forKey: Key.mux)
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
        defaults.set(configuration.mux, forKey: Key.mux)
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
