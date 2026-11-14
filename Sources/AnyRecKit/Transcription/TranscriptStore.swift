import Foundation

/// A recording's transcript on disk, as layers that each record what they were built from:
///
/// - **Sources** — `transcript-<engine>-<UUID>.json`, one per engine run, never rewritten.
/// - **Speakers** — `speakers-<UUID>.json`: who said each line and what each voice is called.
/// - **Wording** — `wording-<UUID>.json`: the review's corrections to specific lines.
/// - **Summary** — `summary-<engine>-<UUID>.json`, with the basis it was written from.
///
/// `.transcription.json` selects one of each. Every file is complete before it is selected,
/// so a failed run leaves the previous selection in place, and nothing selected is deleted,
/// so older versions stay on disk. Markdown and SRT beside the selected source are renderings,
/// rewritten whenever a layer changes. Generations written before layers (a transcript,
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

    private static let selectionName = ".transcription.json"

    public static func selection(in directory: URL) -> Selection? {
        let directory = OutputPlan(directory: directory).directory
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(selectionName)),
            let selection = try? JSONDecoder().decode(Selection.self, from: data),
            selection.files.allSatisfy(validName),
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(selection.transcript).path)
        else { return nil }
        return selection
    }

    /// The selected source; for recordings older than selections, the newest transcript
    /// file that is not an uncommitted generation.
    public static func activeTranscript(in directory: URL) -> URL? {
        let directory = OutputPlan(directory: directory).directory
        if let selection = selection(in: directory) { return directory.appendingPathComponent(selection.transcript) }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter {
            $0.lastPathComponent.hasPrefix("transcript-") && $0.pathExtension == "json"
                && UUID(uuidString: String($0.deletingPathExtension().lastPathComponent.suffix(36))) == nil
        }
            .max { (modified($0), $0.lastPathComponent) < (modified($1), $1.lastPathComponent) }
            .map { directory.appendingPathComponent($0.lastPathComponent) }
    }

    /// Every file the current transcript is made of, for knowing when it last changed.
    public static func layerFiles(in directory: URL) -> [URL] {
        let directory = OutputPlan(directory: directory).directory
        guard let selection = selection(in: directory) else {
            return [activeTranscript(in: directory), directory.appendingPathComponent(RecordingVoices.fileName)].compactMap { $0 }
        }
        return [selection.transcript, selection.voices, selection.speakers, selection.wording, selection.summary]
            .compactMap { $0 }.map(directory.appendingPathComponent)
    }

    public static func activeSummary(in directory: URL) -> URL? {
        let directory = OutputPlan(directory: directory).directory
        if let selection = selection(in: directory) { return selection.summary.map(directory.appendingPathComponent) }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let engine = activeTranscript(in: directory).flatMap(Transcript.read)?.engine
        return files.filter { file in
            let matches = engine.map { file.deletingPathExtension().lastPathComponent == "summary-\($0)" } ?? true
            return file.lastPathComponent.hasPrefix("summary-") && matches
        }.max { ($0.pathExtension == "json" ? 1 : 0, $0.lastPathComponent) < ($1.pathExtension == "json" ? 1 : 0, $1.lastPathComponent) }
            .map { directory.appendingPathComponent($0.lastPathComponent) }
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
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let versions = files.filter { $0.lastPathComponent.hasPrefix("transcript-") && $0.pathExtension == "json" }
            .compactMap { url -> SourceVersion? in
                guard let transcript = Transcript.read(url) else { return nil }
                let name = url.lastPathComponent
                let role: SourceVersion.Role = name == selected ? .selected : compared.contains(name) ? .compared : .earlier
                return SourceVersion(url: directory.appendingPathComponent(name), engine: transcript.engine,
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
        let speakers = directory.appendingPathComponent("speakers-\(UUID().uuidString).json")
        try encode(SpeakerLayer(source: source.lastPathComponent, lineCount: transcript.utterances.count, voices: voices),
                   to: speakers)
        written.append(speakers)
        let rendered = try renderFiles(transcript.named(voices?.names ?? [:]), beside: source, written: &written)
        try save(Selection(transcript: source.lastPathComponent, voices: nil, summary: nil, review: nil,
                           speakers: speakers.lastPathComponent, wording: nil, compared: compared.isEmpty ? nil : compared),
                 in: directory)
        published = true
        clearNoSpeech(in: directory)
        return rendered + [source]
    }

    private static func writeSource(_ transcript: Transcript, in directory: URL, written: inout [URL]) throws -> URL {
        let url = directory.appendingPathComponent("transcript-\(transcript.engine)-\(UUID().uuidString).json")
        try JSONEncoder().encode(transcript).write(to: url, options: .withoutOverwriting)
        written.append(url)
        return url
    }

    // MARK: - Wording

    /// Selects a review's result: its wording layer and, since resolving competing names
    /// changes voices, a fresh speakers layer carrying `voices`. Applied only while the
    /// source it was made from is still selected.
    @discardableResult
    public static func publishWording(_ wording: WordingLayer, voices: RecordingVoices?, in directory: URL) throws -> [URL] {
        let directory = OutputPlan(directory: directory).directory
        guard var selection = selection(in: directory), selection.transcript == wording.source,
              let current = RecordingTranscript.read(in: directory) else { return [] }
        var written: [URL] = []
        var published = false
        defer { if !published { for file in written { try? FileManager.default.removeItem(at: file) } } }
        let wordingURL = directory.appendingPathComponent("wording-\(UUID().uuidString).json")
        try encode(wording, to: wordingURL)
        written.append(wordingURL)
        var layer = current.speakers ?? SpeakerLayer(source: wording.source, lineCount: wording.lineCount, voices: nil)
        layer.voices = voices
        let speakersURL = directory.appendingPathComponent("speakers-\(UUID().uuidString).json")
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
        try encode(layer, to: directory.appendingPathComponent(name))
        return try render(in: directory)
    }

    static func migrateToLayers(in directory: URL) throws {
        try pinSelection(in: directory)
        guard var selection = selection(in: directory), selection.speakers == nil,
              let transcript = Transcript.read(directory.appendingPathComponent(selection.transcript)) else { return }
        let voices = selection.voices.flatMap { RecordingVoices.read(directory.appendingPathComponent($0)) }
        let speakers = directory.appendingPathComponent("speakers-\(UUID().uuidString).json")
        try encode(SpeakerLayer(source: selection.transcript, lineCount: transcript.utterances.count, voices: voices), to: speakers)
        selection.speakers = speakers.lastPathComponent
        selection.voices = nil
        try save(selection, in: directory)
    }

    // MARK: - Summary

    public static func summaryDestination(for transcript: URL) -> URL {
        let name = transcript.lastPathComponent.replacingOccurrences(of: "transcript-", with: "summary-",
                                                                    options: .anchored)
        return OutputPlan(directory: transcript.deletingLastPathComponent()).directory.appendingPathComponent(name)
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
        let directory = OutputPlan(directory: transcript.deletingLastPathComponent()).directory
        guard activeTranscript(in: directory)?.standardizedFileURL == transcript.standardizedFileURL else { return false }
        try pinSelection(in: directory)
        guard var selection = selection(in: directory) else { return false }
        selection.summary = summary.lastPathComponent
        try save(selection, in: directory)
        return true
    }

    // MARK: - Rendering

    /// Markdown and SRT for the selected transcript with names in, beside its source, and
    /// the summary's Markdown with labels filled in. Renderings only: the JSON is the truth.
    @discardableResult
    public static func render(in directory: URL) throws -> [URL] {
        let directory = OutputPlan(directory: directory).directory
        guard let current = RecordingTranscript.read(in: directory) else { return [] }
        var written: [URL] = []
        let files = try renderFiles(current.named, beside: current.url, written: &written)
        if let summary = activeSummary(in: directory), summary.pathExtension == "json", let stored = Summary.read(summary) {
            try? stored.renderMarkdown(beside: summary, names: current.voices?.names ?? [:])
        }
        return files + [current.url]
    }

    private static func renderFiles(_ transcript: Transcript, beside source: URL, written: inout [URL]) throws -> [URL] {
        let base = source.deletingPathExtension()
        let markdown = base.appendingPathExtension("md"), subtitles = base.appendingPathExtension("srt")
        try transcript.markdown(title: source.deletingLastPathComponent().lastPathComponent)
            .write(to: markdown, atomically: true, encoding: .utf8)
        written.append(markdown)
        try transcript.srt.write(to: subtitles, atomically: true, encoding: .utf8)
        written.append(subtitles)
        return [markdown, subtitles]
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
        let voices = directory.appendingPathComponent(RecordingVoices.fileName)
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
        try JSONEncoder().encode(selection).write(to: directory.appendingPathComponent(selectionName), options: .atomic)
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && (name as NSString).lastPathComponent == name
    }
}
