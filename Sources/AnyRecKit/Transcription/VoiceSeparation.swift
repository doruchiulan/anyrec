import FluidAudio
import Foundation

/// One stretch of one voice, as a diarizer heard it.
public struct VoiceSegment: Sendable, Equatable {
    public let voice: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(voice: String, start: TimeInterval, end: TimeInterval) {
        self.voice = voice
        self.start = start
        self.end = end
    }
}

public enum VoiceSeparation {
    /// Who said what, from the voices heard over each line. Lines already measured as
    /// yours keep that: the microphone is exact where a model is only confident.
    /// Letters go by first appearance, and each voice's print and longest line come
    /// out alongside, for naming. Any letter an engine put on a line is replaced,
    /// so one recording is lettered from one source.
    public static func assign(
        _ utterances: [Utterance], segments: [VoiceSegment], prints: [String: Voiceprint]
    ) -> (utterances: [Utterance], voices: RecordingVoices) {
        var letters: [String: String] = [:]
        var longest: [String: Utterance] = [:]

        /// One line can still hold two people — whisper hands over paragraphs — so it
        /// is cut at sentence ends and each part asked alone, and stays cut only when
        /// the parts disagree about who was talking.
        let assigned = utterances.flatMap { utterance -> [Utterance] in
            guard utterance.speaker != .me else { return [utterance] }
            let parts = SpeakerAttribution.sentences(of: utterance).map { part -> Utterance in
                var line = part
                guard let voice = dominant(segments, from: part.start, to: part.end) else {
                    line.speaker = .others
                    return line
                }
                if letters[voice] == nil { letters[voice] = letter(letters.count) }
                line.speaker = .voice(letters[voice]!)
                return line
            }
            let lines: [Utterance]
            if Set(parts.map(\.speaker)).count > 1 {
                lines = parts
            } else {
                var line = utterance
                line.speaker = parts[0].speaker
                lines = [line]
            }
            for line in lines {
                guard case .voice(let letter) = line.speaker,
                    (longest[letter].map { $0.text.count } ?? -1) < line.text.count
                else { continue }
                longest[letter] = line
            }
            return lines
        }

        let voices = letters.sorted { $0.value < $1.value }.map { voice, letter in
            let sample = longest[letter]!
            return RecordingVoices.Voice(
                letter: letter, print: prints[voice] ?? [], sample: sample.text,
                start: sample.start, end: sample.end)
        }
        return (assigned, RecordingVoices(voices: voices))
    }

    /// The voice heard for the longest over a span. Nil when no voice was heard there
    /// at all, which keeps a line nobody was found for with the call rather than
    /// inventing someone.
    static func dominant(
        _ segments: [VoiceSegment], from start: TimeInterval, to end: TimeInterval
    ) -> String? {
        var heard: [String: TimeInterval] = [:]
        for segment in segments {
            let overlap = min(segment.end, end) - max(segment.start, start)
            guard overlap > 0 else { continue }
            heard[segment.voice, default: 0] += overlap
        }
        return heard.max { $0.value < $1.value }?.key
    }

    static func letter(_ index: Int) -> String {
        index < 26 ? String(UnicodeScalar(UInt8(65 + index))) : "\(index + 1)"
    }

    /// Names, from the library, for every voice whose print lands close enough to
    /// someone known. The rest stay letters until somebody says.
    public static func recognise(_ voices: inout RecordingVoices, in library: VoiceLibrary) {
        for index in voices.voices.indices where voices.voices[index].name == nil {
            voices.voices[index].name = library.match(voices.voices[index].print)?.name
        }
    }

    /// Engine labels remain nameable even when no local voiceprints can be extracted.
    public static func lettersOnly(_ utterances: [Utterance]) -> RecordingVoices? {
        var longest: [String: Utterance] = [:]
        for utterance in utterances {
            guard case .voice(let letter) = utterance.speaker else { continue }
            if (longest[letter].map { $0.text.count } ?? -1) < utterance.text.count {
                longest[letter] = utterance
            }
        }
        guard !longest.isEmpty else { return nil }
        let voices = longest.sorted { $0.key < $1.key }.map { letter, sample in
            RecordingVoices.Voice(
                letter: letter, print: [], sample: sample.text, start: sample.start,
                end: sample.end)
        }
        return RecordingVoices(voices: voices)
    }
}

extension VoiceSeparation {
    public static var isAvailable: Bool { SpeakerSetup.isReady }

    /// The voices in a file and a print for each, from the models in the models folder
    /// and nowhere else: this never downloads. The prints are the model's own centroid
    /// per voice, which is what the library keeps and compares.
    public static func separate(
        _ url: URL, progress: @escaping @Sendable (String) -> Void
    ) async throws -> (segments: [VoiceSegment], prints: [String: Voiceprint]) {
        SpeakerSetup.quiet()
        ModelHub.offlineMode = true
        let models = try await OfflineDiarizerModels.load(from: SpeakerSetup.directory)
        let manager = OfflineDiarizerManager(config: .default)
        manager.initialize(models: models)
        do {
            /// FluidAudio 0.17.7 writes two "[Profiling]" lines straight to stderr with
            /// no switch, and the terminal is in normal mode by now. Errors are thrown,
            /// not printed, so nothing worth reading goes with them.
            let result = try await withStandardErrorSilenced {
                try await manager.process(url) { done, total in
                    progress("\(done) of \(total)")
                }
            }
            let segments = result.segments.map {
                VoiceSegment(
                    voice: $0.speakerId, start: TimeInterval($0.startTimeSeconds),
                    end: TimeInterval($0.endTimeSeconds))
            }
            return (segments, result.speakerDatabase ?? [:])
        } catch OfflineDiarizationError.noSpeechDetected {
            return ([], [:])
        }
    }

    private static func withStandardErrorSilenced<T>(
        _ work: () async throws -> T
    ) async rethrows -> T {
        let saved = dup(STDERR_FILENO)
        let null = open("/dev/null", O_WRONLY)
        guard saved >= 0, null >= 0 else { return try await work() }
        dup2(null, STDERR_FILENO)
        defer {
            dup2(saved, STDERR_FILENO)
            close(saved)
            close(null)
        }
        return try await work()
    }
}
