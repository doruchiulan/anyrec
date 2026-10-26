import Foundation
import AnyRecKit

/// Asking who each lettered voice is, in a plain terminal: one question per letter,
/// with the longest thing it said as the clue. Used after a transcript and by
/// `anyrec speakers`; the Kit does the naming, this only asks.
enum SpeakerPrompt {
    /// Nothing is asked when every voice has a name, or when nobody is at the keyboard.
    static func offer(_ voices: RecordingVoices?, in folder: URL) {
        guard let voices, !voices.unnamed.isEmpty, Terminal.isInteractive else { return }
        print("")
        print(
            "\(voices.unnamed.count) \(voices.unnamed.count == 1 ? "voice is" : "voices are") "
                + "still lettered. Name them now and they are remembered for next time; "
                + "⏎ leaves one as it is.")
        let names = ask(voices)
        guard !names.isEmpty else { return }
        apply(names, in: folder)
    }

    static func ask(_ voices: RecordingVoices) -> [String: String] {
        var names: [String: String] = [:]
        for voice in voices.unnamed {
            print("")
            print("  Speaker \(voice.letter) — [\(clock(voice.start))] \(voice.sample)")
            print("  Who is this? ", terminator: "")
            guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty
            else { continue }
            names[voice.letter] = line
        }
        return names
    }

    static func apply(_ names: [String: String], in folder: URL) {
        do {
            let (voices, written) = try VoiceNaming.apply(names, in: folder)
            print("")
            print(listing(voices))
            for url in written where url.pathExtension == "md" { print("  Wrote \(url.path)") }
            let library = VoiceLibrary.load()
            print("  Remembered: \(library.names.joined(separator: ", ")).")
        } catch {
            print("  The names were not saved: \(error)")
        }
    }

    static func listing(_ voices: RecordingVoices) -> String {
        voices.voices.map { voice in
            let who =
                voice.name.map { "\($0) (Speaker \(voice.letter))" } ?? "Speaker \(voice.letter)"
            return "  \(who)\n    [\(clock(voice.start))] \(voice.sample)"
        }
        .joined(separator: "\n")
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
