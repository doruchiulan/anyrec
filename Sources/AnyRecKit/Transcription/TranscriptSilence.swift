import Foundation

extension TranscriptStore {
    private struct AudioRevision: Codable, Equatable {
        let name: String
        let bytes: Int
        let modified: Date
    }

    private static let silenceName = ".transcription-no-speech.json"

    public static func noSpeechDetected(in directory: URL) -> Bool {
        let plan = OutputPlan(directory: directory)
        guard let data = try? Data(contentsOf: plan.directory.appendingPathComponent(silenceName)),
            let previous = try? JSONDecoder().decode([AudioRevision].self, from: data),
            let current = audioRevision(plan), !current.isEmpty else { return false }
        return previous == current
    }

    public static func recordNoSpeech(in directory: URL) throws {
        let plan = OutputPlan(directory: directory)
        guard let revision = audioRevision(plan), !revision.isEmpty else { return }
        try JSONEncoder().encode(revision)
            .write(to: plan.directory.appendingPathComponent(silenceName), options: .atomic)
    }

    static func clearNoSpeech(in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(silenceName))
    }

    private static func audioRevision(_ plan: OutputPlan) -> [AudioRevision]? {
        var files = TranscriptionService.tracks(in: plan).map(\.url)
        guard !files.isEmpty else { return [] }
        if FileManager.default.fileExists(atPath: plan.microphoneLive.path) { files.append(plan.microphoneLive) }
        return try? files.map {
            let values = try $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let bytes = values.fileSize, let modified = values.contentModificationDate else {
                throw CocoaError(.fileReadUnknown)
            }
            return AudioRevision(name: $0.lastPathComponent, bytes: bytes, modified: modified)
        }
    }
}
