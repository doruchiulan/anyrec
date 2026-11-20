import Foundation

public enum SharedCopy {
    public static func exists(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: RecordingLayout(directory: directory).url("shared-copy").path)
    }

    public static func edit(in directory: URL, original: Transcript, lines: [Utterance]) throws {
        guard exists(in: directory), let current = RecordingTranscript.read(in: directory),
              current.named == original, let source = Transcript.read(current.url),
              lines.count == source.utterances.count else {
            throw RecordingShare.Failure.failed("The transcript changed. Reopen it to edit the current version.")
        }
        let changes = try lines.enumerated().compactMap { index, line -> WordingLayer.Change? in
            guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  line.start == original.utterances[index].start, line.end == original.utterances[index].end
            else { throw CocoaError(.validationMissingMandatoryProperty) }
            return line.text == source.utterances[index].text ? nil : .init(line: index, text: line.text)
        }
        let wording = WordingLayer(source: current.url.lastPathComponent, lineCount: lines.count, provider: nil,
                                   changes: changes, compared: [], suggestions: [], speakerChanges: [], failures: [],
                                   batchFailures: [], batchCount: 0, notes: [])
        _ = try TranscriptStore.publishWording(wording, voices: nil, speakers: lines.map(\.speaker), in: directory)
    }
}
