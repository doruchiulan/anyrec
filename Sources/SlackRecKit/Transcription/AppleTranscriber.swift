import AVFoundation
import Foundation
import Speech

/// macOS 26's on-device `SpeechAnalyzer`. Roughly eight times faster than
/// realtime and it needs no permission prompt, but it only ships models for
/// thirty locales — Romanian is not one of them.
@available(macOS 26, *)
public struct AppleTranscriber: Transcriber {
    public let name = "apple"
    private let locale: Locale

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// `SpeechTranscriber.supportedLocale(equivalentTo:)` answers for locales it
    /// cannot actually transcribe, so the supported list is matched by hand.
    public static func locale(for language: String) async -> Locale? {
        guard let wanted = Locale.Language(identifier: language).languageCode?.identifier else {
            return nil
        }
        let supported = await SpeechTranscriber.supportedLocales
        return supported.first { $0.language.languageCode?.identifier == wanted && $0.identifier.hasPrefix(wanted) }
            ?? supported.first { $0.language.languageCode?.identifier == wanted }
    }

    public static func supportedLanguages() async -> [String] {
        let locales = await SpeechTranscriber.supportedLocales
        return Set(locales.compactMap { $0.language.languageCode?.identifier }).sorted()
    }

    public init(locale: Locale) throws {
        guard Self.isAvailable else { throw TranscriptionError.appleUnavailable }
        self.locale = locale
    }

    /// `regions` are ignored: `SpeechAnalyzer` does its own voice detection.
    public func speech(
        of url: URL, in regions: [Range<TimeInterval>], language: String?
    ) async throws -> Speech {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await install(transcriber)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collected = Task {
            var utterances: [Utterance] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                utterances.append(
                    Utterance(
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        text: text
                    ))
            }
            return utterances
        }

        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return Speech(utterances: try await collected.value)
    }

    private func install(_ transcriber: SpeechTranscriber) async throws {
        guard await AssetInventory.status(forModules: [transcriber]) != .installed else { return }
        guard
            let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        else { throw TranscriptionError.unsupportedLanguage(engine: name, language: locale.identifier) }
        try await request.downloadAndInstall()
    }
}
