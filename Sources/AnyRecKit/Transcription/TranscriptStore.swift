import Foundation

public enum TranscriptStore {
    public struct Selection: Codable, Equatable, Sendable {
        public let transcript: String
        public let voices: String?
        public var summary: String?
        public var review: String? = nil
    }

    private static let selectionName = ".transcription.json"

    public static func selection(in directory: URL) -> Selection? {
        let directory = OutputPlan(directory: directory).directory
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(selectionName)),
            let selection = try? JSONDecoder().decode(Selection.self, from: data),
            [selection.transcript, selection.voices, selection.summary, selection.review].compactMap({ $0 }).allSatisfy(validName),
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(selection.transcript).path)
        else { return nil }
        return selection
    }

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

    public static func voicesURL(in directory: URL) -> URL? {
        let directory = OutputPlan(directory: directory).directory
        if let selection = selection(in: directory) { return selection.voices.map(directory.appendingPathComponent) }
        return directory.appendingPathComponent(RecordingVoices.fileName)
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

    public static func summaryDestination(for transcript: URL) -> URL {
        let name = transcript.lastPathComponent.replacingOccurrences(of: "transcript-", with: "summary-",
                                                                    options: .anchored)
        return OutputPlan(directory: transcript.deletingLastPathComponent()).directory.appendingPathComponent(name)
    }

    @discardableResult
    public static func selectSummary(_ summary: URL, for transcript: URL) throws -> Bool {
        let directory = OutputPlan(directory: transcript.deletingLastPathComponent()).directory
        guard activeTranscript(in: directory)?.standardizedFileURL == transcript.standardizedFileURL else { return false }
        let current = selection(in: directory)
        let voices = voicesURL(in: directory).flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0.lastPathComponent : nil
        }
        let updated = Selection(transcript: current?.transcript ?? transcript.lastPathComponent,
                                voices: voices, summary: summary.lastPathComponent, review: current?.review)
        try save(updated, in: directory)
        return true
    }

    @discardableResult
    public static func publish(_ transcript: Transcript, voices: RecordingVoices?, in directory: URL,
                               review: TranscriptReview? = nil) throws -> [URL] {
        let directory = OutputPlan(directory: directory).directory
        try pinSelection(in: directory)
        let generation = UUID().uuidString
        let name = "transcript-\(transcript.engine)-\(generation)"
        let files = ["md", "srt", "json"].map { directory.appendingPathComponent("\(name).\($0)") }
        let voicesURL = directory.appendingPathComponent("voices-\(generation).json")
        let reviewURL = directory.appendingPathComponent("review-\(generation).json")
        var published = false
        defer {
            if !published { for file in files + [voicesURL, reviewURL] { try? FileManager.default.removeItem(at: file) } }
        }
        try TranscriptionService.write(transcript, into: directory, named: name, names: voices?.names ?? [:])
        try voices?.write(to: voicesURL)
        if let review { try JSONEncoder().encode(review).write(to: reviewURL, options: .atomic) }
        try save(Selection(transcript: files[2].lastPathComponent,
                           voices: voices == nil ? nil : voicesURL.lastPathComponent, summary: nil,
                           review: review == nil ? nil : reviewURL.lastPathComponent), in: directory)
        published = true
        clearNoSpeech(in: directory)
        return files
    }

    public static func revision(of urls: [URL?]) -> Date? {
        urls.compactMap { $0 }.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    static func pinSelection(in directory: URL) throws {
        let directory = OutputPlan(directory: directory).directory
        guard selection(in: directory) == nil, let transcript = activeTranscript(in: directory) else { return }
        let voices = voicesURL(in: directory).flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0.lastPathComponent : nil
        }
        try save(Selection(transcript: transcript.lastPathComponent, voices: voices,
                           summary: activeSummary(in: directory)?.lastPathComponent), in: directory)
    }

    private static func modified(_ url: URL) -> Date { revision(of: [url]) ?? .distantPast }

    private static func save(_ selection: Selection, in directory: URL) throws {
        try JSONEncoder().encode(selection).write(to: directory.appendingPathComponent(selectionName), options: .atomic)
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && (name as NSString).lastPathComponent == name
    }
}
