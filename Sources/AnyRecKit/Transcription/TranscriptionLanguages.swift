import Foundation
import whisper

public enum TranscriptionLanguages {
    // Pinned Parakeet v3 model: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
    public static let parakeet: [String] = {
        let codes = [
            "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
            "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
        ]
        let english = Locale(identifier: "en")
        return codes.map { english.localizedString(forLanguageCode: $0) ?? $0 }.sorted()
    }()

    public static let whisper: [String] = {
        (0...whisper_lang_max_id()).compactMap { id in
            whisper_lang_str_full(id).map { String(cString: $0).capitalized }
        }.sorted()
    }()
}
