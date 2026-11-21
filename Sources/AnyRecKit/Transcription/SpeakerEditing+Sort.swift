import Foundation

extension SpeakerEditing {
    @discardableResult
    public static func sort(_ source: Speaker, picks: [Int: Speaker], in directory: URL) throws -> [URL] {
        try TranscriptStore.updateSpeakers(in: directory) { layer, current in
            var speakers = current.transcript.utterances.map(\.speaker)
            let lines = speakers.indices.filter { speakers[$0] == source }
            guard !lines.isEmpty, Set(lines) == Set(picks.keys) else {
                throw TranscriptionError.engineFailed(engine: "transcript", log: "The lines changed. Reopen this recording to sort them.")
            }
            let retained = majorityName(for: source, on: lines, picks: picks, speakers: speakers, voices: layer.voices)
            if case .voice(let letter) = source,
               let index = layer.voices?.voices.firstIndex(where: { $0.letter == letter }) {
                layer.voices?.voices[index].linesSortedByOwner = true
                if let retained {
                    layer.voices?.name(letter, retained)
                    layer.voices?.voices[index].kept = .mixed
                }
            }
            let retainedTarget = retained.map(Speaker.named)
            for (line, target) in picks {
                speakers[line] = target == retainedTarget ? source : target
            }
            layer.speakers = speakers
        }
    }

    private static func majorityName(for source: Speaker, on lines: [Int], picks: [Int: Speaker],
                                     speakers: [Speaker], voices: RecordingVoices?) -> String? {
        guard case .voice(let letter) = source, let voice = voices?.voices.first(where: { $0.letter == letter }),
              voice.filed == nil, !picks.values.contains(source) else { return nil }
        let counts = Dictionary(grouping: picks.values, by: { $0 }).mapValues(\.count)
        guard let main = lines.compactMap({ picks[$0] }).max(by: { counts[$0, default: 0] < counts[$1, default: 0] }),
              case .named(let name) = main, !speakers.contains(main) else { return nil }
        return name
    }
}
