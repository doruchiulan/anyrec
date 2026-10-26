import Foundation
import Testing
@testable import AnyRecKit

@Suite("Speaker recognition with engine labels")
struct SpeakerRecognitionTests {
    private let lines = [
        Utterance(start: 0, end: 5, text: "First speaker. Two sentences.", speaker: .voice("B")),
        Utterance(start: 5, end: 10, text: "Another speaker", speaker: .voice("A")),
        Utterance(start: 10, end: 15, text: "First speaker again", speaker: .voice("B")),
    ]
    private var source: TranscriptionService.Source {
        .init(url: URL(filePath: "/unused.wav"), regions: [], microphone: nil, systemAudio: nil, only: nil, mix: nil)
    }
    private func print(_ index: Int) -> Voiceprint {
        var value = [Float](repeating: 0, count: 256)
        value[index] = 1
        return value
    }

    @Test("OpenAI retains every segment and label while saved people are recognised")
    func openAI() async throws {
        let transcript = Transcript(utterances: lines, language: nil, engine: "openai")
        let result = await TranscriptionService.separate(transcript, in: source, progress: { _ in },
            modelsReady: true, recognizeVoices: { _, heard in
                let voices = try #require(VoiceSeparation.lettersOnly(heard))
                return SpeakerRecognition.enrich(voices, utterances: heard,
                    library: VoiceLibrary(people: [.init(name: "Alex", prints: [print(0)])])) { span in
                        print(span.lowerBound < 5 || span.lowerBound > 10 ? 0 : 1)
                    }
            }, diarize: { _ in
                Issue.record("OpenAI must not run local diarization")
                return ([], [:])
            })
        #expect(result.0 == lines)
        #expect(result.1?.names == ["B": "Alex"])
        #expect(result.1?.voices.first(where: { $0.letter == "A" })?.print == print(1))
    }

    @Test("Single-track OpenAI keeps labels and still matches voices")
    func singleTrack() async {
        let single = TranscriptionService.Source(url: source.url, regions: [], microphone: nil,
                                                systemAudio: nil, only: .others, mix: nil)
        #expect(TranscriptionService.attribute(lines, in: single, preservingSpeakers: true) == lines)
        let result = await TranscriptionService.separate(
            Transcript(utterances: lines, language: nil, engine: "openai"), in: single,
            progress: { _ in }, modelsReady: true, recognizeVoices: { _, heard in
                #expect(heard == lines)
                return VoiceSeparation.lettersOnly(heard)
            }, diarize: { _ in
                Issue.record("Single-track OpenAI must not run local diarization")
                return ([], [:])
            })
        #expect(result.0 == lines)
        #expect(result.1?.voices.map(\.letter) == ["A", "B"])
    }

    @Test("Track attribution cannot split or rename diarized segments")
    func preservesBeforeAttribution() {
        let mic = AudioEnvelope(frames: Array(repeating: 900, count: 750))
        let call = AudioEnvelope(frames: Array(repeating: 1, count: 750))
        let mixed = TranscriptionService.Source(url: source.url, regions: [], microphone: mic,
                                               systemAudio: call, only: nil, mix: .plain)
        #expect(TranscriptionService.attribute(lines, in: mixed, preservingSpeakers: true) == lines)
        #expect(TranscriptionService.attribute(lines, in: mixed).map(\.speaker) == [.me, .me, .me])
    }

    @Test("Missing models and failed recognition keep OpenAI speakers nameable", arguments: [false, true])
    func unavailable(modelsReady: Bool) async {
        let result = await TranscriptionService.separate(
            Transcript(utterances: lines, language: nil, engine: "openai"), in: source,
            progress: { _ in }, modelsReady: modelsReady, recognizeVoices: { _, _ in
                #expect(modelsReady)
                throw SpeakerEmbedding.Failure.invalidEmbedding
            }, diarize: { _ in
                Issue.record("Failure must not fall back to reassigning speakers")
                return ([], [:])
            })
        #expect(result.0 == lines)
        #expect(result.1?.voices.map(\.letter) == ["A", "B"])
        #expect(result.1?.voices.allSatisfy { $0.print.isEmpty } == true)
    }

    @Test("Local engines keep local diarization", arguments: ["parakeet", "apple", "whisper"])
    func local(engine: String) async {
        let result = await TranscriptionService.separate(
            Transcript(utterances: lines, language: nil, engine: engine), in: source,
            progress: { _ in }, modelsReady: true, recognizeVoices: { _, _ in
                Issue.record("Local engines need diarization first")
                return nil
            }, diarize: { _ in
                ([VoiceSegment(voice: "local", start: 0, end: 15)], ["local": print(0)])
            })
        #expect(result.0.map(\.speaker) == [.voice("A"), .voice("A"), .voice("A")])
        #expect(result.1?.voices.count == 1)
    }

    @Test("Samples exclude overlap, brief speech, invalid times and excessive duration")
    func cleanSamples() {
        let input = [
            Utterance(start: 0, end: 5, text: "Overlapping", speaker: .voice("A")),
            Utterance(start: 3, end: 4, text: "Interruption", speaker: .voice("B")),
            Utterance(start: 6, end: 7, text: "Brief", speaker: .voice("A")),
            Utterance(start: 10, end: 40, text: "Clean", speaker: .voice("A")),
            Utterance(start: .infinity, end: .infinity, text: "Invalid", speaker: .voice("A")),
        ]
        #expect(SpeakerRecognition.samples(for: "A", in: input) == [20..<30])
        #expect(SpeakerRecognition.samples(for: "B", in: input).isEmpty)
    }

    @Test("Conflicting or unusable embeddings cannot name or enroll a speaker")
    func unreliablePrints() throws {
        #expect(SpeakerRecognition.combined([print(0), print(1)]).isEmpty)
        #expect(SpeakerRecognition.combined([[Float](repeating: .nan, count: 256)]).isEmpty)
        #expect(SpeakerRecognition.combined([[Float](repeating: 0, count: 256)]).isEmpty)
        #expect(SpeakerRecognition.combined([[1, 2]]).isEmpty)
        let voices = try #require(VoiceSeparation.lettersOnly(lines))
        let result = SpeakerRecognition.enrich(voices, utterances: lines,
            library: VoiceLibrary(people: [.init(name: "Alex", prints: [print(0)])])) { _ in
                throw SpeakerEmbedding.Failure.insufficientAudio
            }
        #expect(result.names.isEmpty)
        #expect(result.voices.allSatisfy { $0.print.isEmpty })
    }
}
