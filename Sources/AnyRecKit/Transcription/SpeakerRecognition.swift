import FluidAudio
import Foundation

enum SpeakerRecognition {
    static func recognise(_ url: URL, _ utterances: [Utterance]) async throws -> RecordingVoices? {
        guard let voices = VoiceSeparation.lettersOnly(utterances) else { return nil }
        guard voices.voices.contains(where: { !samples(for: $0.letter, in: utterances).isEmpty }) else {
            return voices
        }
        SpeakerSetup.quiet()
        ModelHub.offlineMode = true
        let models = try await OfflineDiarizerModels.load(from: SpeakerSetup.directory)
        let embedding = SpeakerEmbedding(models: models)
        return enrich(voices, utterances: utterances, library: VoiceLibrary.load()) { span in
            let audio = try AudioSamples.read(url, seconds: span.upperBound - span.lowerBound, start: span.lowerBound)
            return try embedding.extract(audio)
        }
    }

    static func enrich(
        _ voices: RecordingVoices, utterances: [Utterance], library: VoiceLibrary,
        extract: (Range<Double>) throws -> Voiceprint
    ) -> RecordingVoices {
        var result = RecordingVoices(voices: voices.voices.map { voice in
            let prints = samples(for: voice.letter, in: utterances).compactMap { try? extract($0) }
            return RecordingVoices.Voice(letter: voice.letter, print: combined(prints),
                sample: voice.sample, start: voice.start, end: voice.end, name: voice.name)
        })
        VoiceSeparation.recognise(&result, in: library)
        return result
    }

    static func samples(for letter: String, in utterances: [Utterance]) -> [Range<Double>] {
        let valid = utterances.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
        let speaker = Speaker.voice(letter)
        return valid.filter { line in
            line.speaker == speaker && line.end - line.start >= 2.3 && !valid.contains {
                $0.speaker != speaker && $0.start < line.end && $0.end > line.start
            }
        }
        .sorted {
            let left = $0.end - $0.start, right = $1.end - $1.start
            return left == right ? $0.start < $1.start : left > right
        }
        .prefix(3)
        .map { line in
            let length = min(10, line.end - line.start - 0.3)
            let start = line.start + (line.end - line.start - length) / 2
            return start..<(start + length)
        }
    }

    static func combined(_ prints: [Voiceprint]) -> Voiceprint {
        let valid = prints.filter { $0.count == 256 && $0.allSatisfy(\.isFinite) && $0.contains(where: { $0 != 0 }) }
        guard let first = valid.first else { return [] }
        guard valid.allSatisfy({ a in valid.allSatisfy { VoiceLibrary.similarity(a, $0) >= VoiceLibrary.threshold } }) else {
            return []
        }
        return first.indices.map { index in valid.reduce(Float(0)) { $0 + $1[index] } / Float(valid.count) }
    }
}
