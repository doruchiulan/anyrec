import Foundation

/// Who said each line of one source transcript, and what each voice is called. Naming a
/// voice or accepting a speaker correction changes this layer and nothing else.
public struct SpeakerLayer: Codable, Equatable, Sendable {
    static let version = 1
    public var version = SpeakerLayer.version
    /// The source transcript file this layer applies to.
    public let source: String
    /// How many lines that source has; a layer for another line count is not applied.
    public let lineCount: Int
    /// The speaker of every line, when any differs from the source's own. Nil keeps the
    /// source's speakers.
    public var speakers: [Speaker]?
    public var voices: RecordingVoices?
    /// Lines whose speaker suggestion has been acted on, so it is not offered again.
    public var decided: [Int] = []

    public init(source: String, lineCount: Int, speakers: [Speaker]? = nil, voices: RecordingVoices?) {
        self.source = source
        self.lineCount = lineCount
        self.speakers = speakers
        self.voices = voices
    }
}

/// The review's corrections, as changes to specific lines of one source transcript, with
/// what it suggested and what it could not do. Re-running review replaces this layer and
/// nothing else.
public struct WordingLayer: Codable, Equatable, Sendable {
    public struct Change: Codable, Equatable, Sendable {
        public let line: Int
        public let text: String
    }

    static let version = 1
    public var version = WordingLayer.version
    public let source: String
    public let lineCount: Int
    public let provider: SummaryProvider?
    public let changes: [Change]
    /// Other engines' source files the reviewer compared.
    public let compared: [String]
    public let suggestions: [SpeakerSuggestion]
    public let speakerChanges: [SpeakerCorrection]
    public let failures: [String]
    public let batchFailures: [ReviewBatchFailure]
    public let batchCount: Int
    public let notes: [String]
    /// What the reviewer was told about the whole call (`CallSheet`), so a change, or a word
    /// left alone, can be traced to it. Absent in layers written before it existed.
    public var callSheet: CallSheet? = nil
}

/// A recording's transcript as it reads now, rendered from its layers: the source an
/// engine wrote, the speakers layer, the wording layer. What every interface shows —
/// the app, Markdown and SRT, MCP — and what a summary is written from. Generations
/// written before layers, and recordings older than generations, read through the same
/// type without being rewritten.
public struct RecordingTranscript: Sendable {
    /// The source transcript file (or, for older formats, the generation's transcript).
    public let url: URL
    /// The lines with wording and speakers applied; voices still lettered.
    public let transcript: Transcript
    public let voices: RecordingVoices?
    public let speakers: SpeakerLayer?
    public let wording: WordingLayer?
    /// A generation's review file, for recordings published before layers.
    public let legacyReview: TranscriptReview?
    public let selection: TranscriptStore.Selection?

    /// The transcript with every named voice carrying its name.
    public var named: Transcript { transcript.named(voices?.names ?? [:]) }

    /// Whether this was written in layers. Older formats are migrated the first time the
    /// owner changes something, never on read.
    public var isLayered: Bool { selection?.speakers != nil }

    public var reviewProvider: SummaryProvider? { wording?.provider ?? legacyReview?.provider }
    public var reviewFailures: [String] { wording?.failures ?? legacyReview?.failures ?? [] }

    /// Speaker corrections the review proposed that still apply: not yet acted on, and
    /// the line still has the speaker the suggestion was made against.
    public var pendingSpeakerChanges: [SpeakerCorrection] {
        let proposed = wording?.speakerChanges ?? legacyReview?.speakerChanges ?? []
        let decided = Set(speakers?.decided ?? [])
        return proposed.filter { change in
            !decided.contains(change.line) && transcript.utterances.indices.contains(change.line)
                && transcript.utterances[change.line].speaker == change.from
        }
    }

    /// Names the review read from self-introductions, for voices still unnamed.
    public var nameSuggestions: [SpeakerSuggestion] {
        let suggestions = wording?.suggestions ?? legacyReview?.suggestions ?? []
        let unnamed = Set(voices?.unnamed.map(\.letter) ?? [])
        return suggestions.filter { unnamed.contains($0.letter) }
    }

    public static func read(in directory: URL) -> RecordingTranscript? {
        let directory = OutputPlan(directory: directory).directory
        guard let selection = TranscriptStore.selection(in: directory) else {
            guard let url = TranscriptStore.activeTranscript(in: directory), let transcript = Transcript.read(url) else { return nil }
            return RecordingTranscript(url: url, transcript: transcript,
                                       voices: RecordingVoices.read(RecordingLayout(directory: directory).readURL(RecordingVoices.fileName)),
                                       speakers: nil, wording: nil, legacyReview: nil, selection: nil)
        }
        let layout = RecordingLayout(directory: directory)
        let url = layout.readURL(selection.transcript)
        guard let source = Transcript.read(url) else { return nil }
        guard let speakersName = selection.speakers else {
            return RecordingTranscript(url: url, transcript: source,
                voices: selection.voices.flatMap { RecordingVoices.read(layout.readURL($0)) },
                speakers: nil, wording: nil,
                legacyReview: selection.review.flatMap { TranscriptStore.decode(TranscriptReview.self, layout.readURL($0)) },
                selection: selection)
        }
        let speakers = TranscriptStore.decode(SpeakerLayer.self, layout.readURL(speakersName))
            .flatMap { $0.source == selection.transcript && $0.lineCount == source.utterances.count ? $0 : nil }
        let wording = selection.wording.flatMap { TranscriptStore.decode(WordingLayer.self, layout.readURL($0)) }
            .flatMap { $0.source == selection.transcript && $0.lineCount == source.utterances.count ? $0 : nil }
        let legacy = selection.review.flatMap { TranscriptStore.decode(TranscriptReview.self, layout.readURL($0)) }
        return RecordingTranscript(url: url, transcript: render(source, speakers: speakers, wording: wording),
                                   voices: speakers?.voices, speakers: speakers, wording: wording,
                                   legacyReview: legacy, selection: selection)
    }

    static func render(_ source: Transcript, speakers: SpeakerLayer?, wording: WordingLayer?) -> Transcript {
        var lines = source.utterances
        if let assigned = speakers?.speakers, assigned.count == lines.count {
            for index in lines.indices { lines[index].speaker = assigned[index] }
        }
        for change in wording?.changes ?? [] where lines.indices.contains(change.line) {
            lines[change.line].text = change.text
        }
        return Transcript(keeping: lines, language: source.language,
                          engine: wording?.provider == nil ? source.engine : "reviewed",
                          notes: source.notes + (wording?.notes ?? []))
    }
}
