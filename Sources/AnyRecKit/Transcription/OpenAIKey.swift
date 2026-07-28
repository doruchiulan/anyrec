import Foundation

/// Where the one secret this tool reads lives. It is the user's own key, it is never
/// sent anywhere but OpenAI, and it never appears in output — not in a log, not in
/// an error, not on the screen it was typed into.
public enum OpenAIKey {
    public static var file: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/anyrec/openai-key")
    }

    public enum Failure: Error, LocalizedError, CustomStringConvertible {
        case empty
        case rejected(String)

        public var description: String {
            switch self {
            case .empty: "No key was entered."
            case .rejected(let complaint): "OpenAI would not accept that key: \(complaint)"
            }
        }

        public var errorDescription: String? { description }
    }

    /// The environment first, so a key can be scoped to one shell; the file is for
    /// people who would rather not export a secret into every process they launch.
    public static func current() -> String? {
        [fromEnvironment, try? String(contentsOf: file, encoding: .utf8)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// True when the key in play came from the shell, where saving one has no effect.
    public static var isFromEnvironment: Bool {
        fromEnvironment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static var fromEnvironment: String? {
        ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }

    /// Written readable by nobody else, and replaced rather than overwritten so the
    /// permissions apply to the key that is actually there.
    public static func store(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }

        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.removeItem(at: file)
        guard
            FileManager.default.createFile(
                atPath: file.path, contents: Data(trimmed.utf8),
                attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: file.path])
        }
    }
}
