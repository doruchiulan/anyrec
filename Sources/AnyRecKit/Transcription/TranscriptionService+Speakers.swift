import Foundation

extension TranscriptionService {
    static func separate(
        _ transcript: Transcript, in source: Source, useDiarization: Bool = true,
        progress: @Sendable (String) -> Void,
        modelsReady: Bool = VoiceSeparation.isAvailable,
        recognizeVoices: (URL, [Utterance]) async throws -> RecordingVoices? = SpeakerRecognition.recognise,
        diarize: (URL) async throws -> (segments: [VoiceSegment], prints: [String: Voiceprint]) = {
            try await VoiceSeparation.separate($0) { _ in }
        }
    ) async -> ([Utterance], RecordingVoices?) {
        let utterances = transcript.utterances
        let preservingSpeakers = transcript.engine == "openai" && useDiarization
        guard preservingSpeakers || source.only == nil else { return (utterances, nil) }
        guard modelsReady else { return (utterances, VoiceSeparation.lettersOnly(utterances)) }
        progress(preservingSpeakers ? "Matching known voices…" : "Telling the voices apart…")
        do {
            if preservingSpeakers {
                return (utterances, try await recognizeVoices(source.url, utterances))
            }
            let heard = try await diarize(source.url)
            var (assigned, voices) = VoiceSeparation.assign(
                utterances, segments: heard.segments, prints: heard.prints)
            VoiceSeparation.recognise(&voices, in: VoiceLibrary.load())
            return (assigned, voices)
        } catch {
            progress("Could not \(preservingSpeakers ? "match known voices" : "tell the voices apart"): \(error.localizedDescription)")
            return (utterances, VoiceSeparation.lettersOnly(utterances))
        }
    }
}
