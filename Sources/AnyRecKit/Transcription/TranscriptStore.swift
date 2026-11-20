import Foundation

/// A recording's transcript on disk, as layers that each record what they were built from:
///
/// - **Sources** — `transcript-<engine>-<UUID>.json`, one per engine run, never rewritten.
/// - **Speakers** — `speakers-<UUID>.json`: who said each line and what each voice is called.
/// - **Wording** — `wording-<UUID>.json`: the review's corrections to specific lines.
/// - **Summary** — `summary-<engine>-<UUID>.json`, with the basis it was written from.
///
/// `Data/transcription.json` selects one of each. Every file is complete before it is
/// selected, so a failed run leaves the previous selection in place, and nothing selected is
/// deleted, so older versions stay on disk. They all live in `Data/Transcripts`
/// (`RecordingLayout`); folders made before that kept them flat and are read as they are.
/// `Transcript.md` and `Summary.md` at the top of the folder are
/// renderings of the current selection, rewritten whenever the selection or a layer changes. Generations written before layers (a transcript,
/// `voices-<UUID>.json` and `review-<UUID>.json` selected together) and recordings older
/// than generations read as they are, and are moved into layers only when the owner
/// changes something.
public enum TranscriptStore {
    public struct Selection: Codable, Equatable, Sendable {
        /// The source transcript (or, in a generation, its transcript).
        public var transcript: String
        /// A generation's voices. Nil in a layered selection, whose voices are in `speakers`.
        public var voices: String?
        public var summary: String?
        /// A generation's review file; kept on a migrated selection for what it compared.
        public var review: String? = nil
        public var speakers: String? = nil
        public var wording: String? = nil
        /// Other engines' sources from the same run, compared by review.
        public var compared: [String]? = nil

        var files: [String] {
            [transcript, voices, summary, review, speakers, wording].compactMap { $0 } + (compared ?? [])
        }
    }

    public static func selection(in directory: URL) -> Selection? {
        let directory = OutputPlan(directory: directory).directory
        let layout = RecordingLayout(directory: directory)
        guard let data = try? Data(contentsOf: layout.selection),
            let selection = try? JSONDecoder().decode(Selection.self, from: data),
            selection.files.allSatisfy(validName),
            FileManager.default.fileExists(atPath: layout.readURL(selection.transcript).path)
        else { return nil }
        return selection
    }

    /// The selected source; for recordings older than selections, the newest transcript
    /// file that is not an uncommitted generation.
    public static func activeTranscript(in directory: URL) -> URL? {
        let directory = OutputPlan(directory: directory).directory
        let layout = RecordingLayout(directory: directory)
        if let selection = selection(in: directory) { return layout.readURL(selection.transcript) }
        return layout.files(in: .transcripts).filter {
            $0.lastPathComponent.hasPrefix("transcript-") && $0.pathExtension == "json"
                && UUID(uuidString: String($0.deletingPathExtension().lastPathComponent.suffix(36))) == nil
        }
            .max { (modified($0), $0.lastPathComponent) < (modified($1), $1.lastPathComponent) }
    }

    /// Every file the current transcript is made of, for knowing when it last changed.
    public static func layerFiles(in directory: URL) -> [URL] {
        let directory = OutputPlan(directory: directory).directory
        guard let selection = selection(in: directory) else {
            return [activeTranscript(in: directory), RecordingLayout(directory: directory).readURL(RecordingVoices.fileName)]
                .compactMap { $0 }
        }
        return [selection.transcript, selection.voices, selection.speakers, selection.wording, selection.summary]
            .compactMap { $0 }.map(RecordingLayout(directory: directory).readURL)
    }

    public static func activeSummary(in directory: URL) -> URL? {
        let directory = OutputPlan(directory: directory).directory
        let layout = RecordingLayout(directory: directory)
        if let selection = selection(in: directory) { return selection.summary.map(layout.readURL) }
        let files = layout.files(in: .transcripts)
        let engine = activeTranscript(in: directory).flatMap(Transcript.read)?.engine
        return files.filter { file in
            let matches = engine.map { file.deletingPathExtension().lastPathComponent == "summary-\($0)" } ?? true
            return file.lastPathComponent.hasPrefix("summary-") && matches
        }.max { ($0.pathExtension == "json" ? 1 : 0, $0.lastPathComponent) < ($1.pathExtension == "json" ? 1 : 0, $1.lastPathComponent) }
    }

    /// The transcript as it reads now, rendered from its layers.
    public static func current(in directory: URL) -> RecordingTranscript? {
        RecordingTranscript.read(in: directory)
    }

    // MARK: - Sources

    /// One transcript an engine wrote for this recording, for showing older versions.
    public struct SourceVersion: Sendable, Equatable, Identifiable {
        public enum Role: Sendable, Equatable { case selected, compared, earlier }
        public let url: URL
        public let engine: String
        public let written: Date
        public let role: Role
        public var id: URL { url }
    }

    /// Every source transcript in the folder — the selected one, the engines it was
    /// compared with, and every earlier version — newest first within each role. Older
    /// generations' transcripts are earlier versions too.
    public static func sources(in directory: URL) -> [SourceVersion] {
        let directory = OutputPlan(directory: directory).directory
        let selection = selection(in: directory)
        let selected = activeTranscript(in: directory)?.lastPathComponent
        let compared = Set(selection?.compared ?? [])
        let files = RecordingLayout(directory: directory).files(in: .transcripts)
        let versions = files.filter { $0.lastPathComponent.hasPrefix("transcript-") && $0.pathExtension == "json" }
            .compactMap { url -> SourceVersion? in
                guard let transcript = Transcript.read(url) else { return nil }
                let name = url.lastPathComponent
                let role: SourceVersion.Role = name == selected ? .selected : compared.contains(name) ? .compared : .earlier
                return SourceVersion(url: url, engine: transcript.engine,
                                     written: modified(url), role: role)
            }
        let rank: (SourceVersion.Role) -> Int = { $0 == .selected ? 0 : $0 == .compared ? 1 : 2 }
        return versions.sorted { (rank($0.role), $1.written) < (rank($1.role), $0.written) }
    }

    /// Publishes one engine run: the primary source, the other engines' sources it may be
    /// compared with, and a speakers layer with `voices`, then selects them together. The
    /// previous selection stays on disk; its summary does not follow, since it describes
    /// another transcript. Returns the rendered Markdown and SRT and the source.
    @discardableResult
    public static func publish(_ transcript: Transcript, voices: RecordingVoices?, in directory: URL,
                               compared others: [Transcript] = []) throws -> [URL] {
        let directory = OutputPlan(directory: directory).directory
        try pinSelection(in: directory)
        var written: [URL] = []
        var published = false
        defer { if !published { for file in written { try? FileManager.default.removeItem(at: file) } } }

        let source = try writeSource(transcript, in: directory, written: &written)
        let compared = try others.map { try writeSource($0, in: directory, written: &written).lastPathComponent }
        let speakers = RecordingLayout(directory: directory).writeURL("speakers-\(UUID().uuidString).json")
        try encode(SpeakerLayer(source: source.lastPathComponent, lineCount: transcript.utterances.count, voices: voices),
                   to: speakers)
        written.append(speakers)
        let rendered = try renderFiles(transcript.named(voices?.names ?? [:]), in: directory, written: &written)
        try save(Selection(transcript: source.lastPathComponent, voices: nil, summary: nil, review: nil,
                           speakers: speakers.lastPathComponent, wording: nil, compared: compared.isEmpty ? nil : compared),
                 in: directory)
        published = true
        clearNoSpeech(in: directory)
        return rendered + [source]
    }

    private static func writeSource(_ transcript: Transcript, in directory: URL, written: inout [URL]) throws -> URL {
        let url = RecordingLayout(directory: directory).writeURL("transcript-\(transcript.engine)-\(UUID().uuidString).json")
        try JSONEncoder().encode(transcript).write(to: url, options: .withoutOverwriting)
        written.append(url)
        return url
    }

    // MARK: - Wording

    /// Selects a review's result: its wording layer and, since resolving competing names
    /// changes voices, a fresh speakers layer carrying `voices`. Applied only while the
    /// source it was made from is still selected.
    @discardableResult
    public static func publishWording(_ wording: WordingLayer, voices: RecordingVoices?, speakers: [Speaker]? = nil, in directory: URL) throws -> [URL] {
        let directory = OutputPlan(directory: directory).directory
        guard var selection = selection(in: directory), selection.transcript == wording.source,
              let current = RecordingTranscript.read(in: directory) else { return [] }
        var written: [URL] = []
        var published = false
        defer { if !published { for file in written { try? FileManager.default.removeItem(at: file) } } }
        let layout = RecordingLayout(directory: directory)
        let wordingURL = layout.writeURL("wording-\(UUID().uuidString).json")
        try encode(wording, to: wordingURL)
        written.append(wordingURL)
        var layer = current.speakers ?? SpeakerLayer(source: wording.source, lineCount: wording.lineCount, voices: nil)
        layer.voices = voices
        if let speakers { layer.speakers = speakers }
        let speakersURL = layout.writeURL("speakers-\(UUID().uuidString).json")
        try encode(layer, to: speakersURL)
        written.append(speakersURL)
        selection.wording = wordingURL.lastPathComponent
        selection.speakers = speakersURL.lastPathComponent
        try save(selection, in: directory)
        published = true
        return try render(in: directory)
    }

    // MARK: - Speakers

    /// Changes who said a line or what a voice is called — one layer, nothing else. An
    /// older generation is first moved into layers (its transcript becomes the source and
    /// its summary stays selected); nothing it wrote is rewritten.
    @discardableResult
    public static func updateSpeakers(
        in directory: URL, _ change: (inout SpeakerLayer, RecordingTranscript) throws -> Void
    ) throws -> [URL] {
        let directory = OutputPlan(directory: directory).directory
        try migrateToLayers(in: directory)
        guard let selection = selection(in: directory), let name = selection.speakers,
              let current = RecordingTranscript.read(in: directory), var layer = current.speakers else {
            throw TranscriptionError.engineFailed(engine: "transcript", log: "This recording's transcript could not be read.")
        }
        try change(&layer, current)
        try encode(layer, to: RecordingLayout(directory: directory).writeURL(name))
        return try render(in: directory)
    }

    static func migrateToLayers(in directory: URL) throws {
        try pinSelection(in: directory)
        guard var selection = selection(in: directory), selection.speakers == nil,
              let transcript = Transcript.read(RecordingLayout(directory: directory).readURL(selection.transcript)) else { return }
        let voices = selection.voices.flatMap { RecordingVoices.read(RecordingLayout(directory: directory).readURL($0)) }
        let speakers = RecordingLayout(directory: directory).writeURL("speakers-\(UUID().uuidString).json")
        try encode(SpeakerLayer(source: selection.transcript, lineCount: transcript.utterances.count, voices: voices), to: speakers)
        selection.speakers = speakers.lastPathComponent
        selection.voices = nil
        try save(selection, in: directory)
    }

    // MARK: - Summary

    public static func summaryDestination(for transcript: URL) -> URL {
        let name = transcript.lastPathComponent.replacingOccurrences(of: "transcript-", with: "summary-",
                                                                    options: .anchored)
        return RecordingLayout.containing(transcript).writeURL(name)
    }

    /// Writes a summary of the transcript read from `transcript` and selects it — unless
    /// another source has been selected since, in which case it is left on disk unselected.
    @discardableResult
    public static func publishSummary(_ summary: Summary, for transcript: URL, names: [String: String]) throws -> URL {
        let destination = summaryDestination(for: transcript)
        try summary.write(to: destination, names: names)
        try selectSummary(destination, for: transcript)
        return destination
    }

    @discardableResult
    public static func selectSummary(_ summary: URL, for transcript: URL) throws -> Bool {
        let directory = RecordingLayout.containing(transcript).directory
        guard activeTranscript(in: directory)?.standardizedFileURL == transcript.standardizedFileURL else { return false }
        try pinSelection(in: directory)
        guard var selection = selection(in: directory) else { return false }
        selection.summary = summary.lastPathComponent
        try save(selection, in: directory)
        try? renderSummary(in: directory)
        return true
    }

    // MARK: - Rendering

    /// `Transcript.md` for the selected transcript with names in, and `Summary.md` for the
    /// selected summary with labels filled in, at the top of the folder. Renderings only:
    /// the JSON is the truth. Subtitles are not kept; `srt(in:)` renders them on demand.
    @discardableResult
    public static func render(in directory: URL) throws -> [URL] {
        let directory = OutputPlan(directory: directory).directory
        guard let current = RecordingTranscript.read(in: directory) else { return [] }
        var written: [URL] = []
        let files = try renderFiles(current.named, in: directory, written: &written)
        try? renderSummary(in: directory, names: current.voices?.names)
        return files + [current.url]
    }

    /// The current transcript as SubRip text, with names in; nil when there is none. Not
    /// kept on disk: made when something needs captions.
    public static func srt(in directory: URL) -> String? {
        RecordingTranscript.read(in: directory)?.named.srt
    }

    /// `Summary.md` from the selected summary; removed when there is none selected.
    static func renderSummary(in directory: URL, names: [String: String]? = nil) throws {
        let layout = RecordingLayout(directory: directory)
        let target = layout.directory.appendingPathComponent(RecordingLayout.summaryMarkdown)
        guard let summary = activeSummary(in: directory) else {
            try? FileManager.default.removeItem(at: target)
            return
        }
        if summary.pathExtension == "json", let stored = Summary.read(summary) {
            let names = names ?? RecordingTranscript.read(in: directory)?.voices?.names ?? [:]
            try stored.named(names).markdown.write(to: target, atomically: true, encoding: .utf8)
        } else if let text = try? String(contentsOf: summary, encoding: .utf8) {
            try text.write(to: target, atomically: true, encoding: .utf8)
        }
    }

    /// Writes the three renderings that are missing, from whatever is selected (or, for a
    /// folder older than selections, the newest transcript). Used by the migration.
    @discardableResult
    static func renderMissing(in directory: URL) -> Bool {
        let layout = RecordingLayout(directory: directory)
        let top = [layout.directory.appendingPathComponent(RecordingLayout.transcriptMarkdown)]
        let summary = layout.directory.appendingPathComponent(RecordingLayout.summaryMarkdown)
        let fm = FileManager.default
        var changed = false
        if let current = RecordingTranscript.read(in: layout.directory),
           !top.allSatisfy({ fm.fileExists(atPath: $0.path) }) {
            var written: [URL] = []
            changed = ((try? renderFiles(current.named, in: layout.directory, written: &written)) != nil) || changed
        }
        if !fm.fileExists(atPath: summary.path), activeSummary(in: layout.directory) != nil {
            try? renderSummary(in: layout.directory)
            changed = true
        }
        return changed
    }

    private static func renderFiles(
        _ transcript: Transcript, in directory: URL, written: inout [URL]
    ) throws -> [URL] {
        let top = RecordingLayout(directory: directory).directory
        let markdown = top.appendingPathComponent(RecordingLayout.transcriptMarkdown)
        try transcript.markdown(title: top.lastPathComponent)
            .write(to: markdown, atomically: true, encoding: .utf8)
        written.append(markdown)
        return [markdown]
    }

    // MARK: - Files

    public static func revision(of urls: [URL?]) -> Date? {
        urls.compactMap { $0 }.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    /// A recording older than selections gets one pointing at what it already has, so a
    /// regeneration can never make its transcript, voices or summary unreachable.
    static func pinSelection(in directory: URL) throws {
        let directory = OutputPlan(directory: directory).directory
        guard selection(in: directory) == nil, let transcript = activeTranscript(in: directory) else { return }
        let voices = RecordingLayout(directory: directory).readURL(RecordingVoices.fileName)
        try save(Selection(transcript: transcript.lastPathComponent,
                           voices: FileManager.default.fileExists(atPath: voices.path) ? voices.lastPathComponent : nil,
                           summary: activeSummary(in: directory)?.lastPathComponent), in: directory)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private static func modified(_ url: URL) -> Date { revision(of: [url]) ?? .distantPast }

    private static func save(_ selection: Selection, in directory: URL) throws {
        try JSONEncoder().encode(selection)
            .write(to: RecordingLayout(directory: directory).writeURL(RecordingLayout.selectionName), options: .atomic)
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && (name as NSString).lastPathComponent == name
    }
}
