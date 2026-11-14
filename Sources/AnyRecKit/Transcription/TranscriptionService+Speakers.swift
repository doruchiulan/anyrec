import Foundation

extension TranscriptionService {
    static func separate(
        _ transcript: Transcript, in source: Source, useDiarization: Bool = true,
        progress: @Sendable (String) -> Void,
        modelsReady: Bool = VoiceSeparation.isAvailable,
        recognizeVoices: (URL, [Utterance]) async throws -> RecordingVoices? = SpeakerRecognition.recognise,
        diarize: (URL) async throws -> (segments: [VoiceSegment], prints: [String: Voiceprint]) = {
            try await VoiceSeparation.separate($0) { _ in }
        },
        evidence: CallParticipants? = nil,
        library: VoiceLibrary? = nil,
        learn: (VoiceLibrary) -> Void = { try? $0.save() }
    ) async -> ([Utterance], RecordingVoices?) {
        let utterances = transcript.utterances
        let preservingSpeakers = transcript.engine == "openai" && useDiarization
        guard preservingSpeakers || source.only == nil else { return (utterances, nil) }
        guard modelsReady else { return (utterances, VoiceSeparation.lettersOnly(utterances)) }
        progress(preservingSpeakers ? "Matching known voices…" : "Telling the voices apart…")
        let library = library ?? VoiceLibrary.load()
        do {
            let lines: [Utterance], voices: RecordingVoices?
            if preservingSpeakers {
                (lines, voices) = (utterances, try await recognizeVoices(source.url, utterances))
            } else {
                let heard = try await DiarizationCache.heard(source.url, in: source.cache, diarize: diarize)
                var (assigned, found) = VoiceSeparation.assign(
                    utterances, segments: heard.segments, prints: heard.prints)
                VoiceSeparation.recognise(&found, in: library)
                (lines, voices) = (assigned, found)
            }
            let microphone = source.microphone.flatMap { mic in
                source.systemAudio.flatMap { SpeakerAttribution.Microphone(microphone: mic, systemAudio: $0, mix: source.mix ?? .plain) }
            }
            let resolved = ParticipantAttribution.resolve(voices, lines: lines, evidence: evidence, library: library,
                                                          microphone: microphone)
            /// A display name that corroborated a voiceprint is filed as that person's
            /// alias. Only names: a print is filed only when somebody names a voice.
            var updated = library
            if resolved.aliases.reduce(false, { updated.addAlias($1.display, to: $1.person) || $0 }) { learn(updated) }
            return (resolved.lines, resolved.voices)
        } catch {
            progress("Could not \(preservingSpeakers ? "match known voices" : "tell the voices apart"): \(error.localizedDescription)")
            return (utterances, VoiceSeparation.lettersOnly(utterances))
        }
    }
}
