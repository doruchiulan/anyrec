import Foundation

/// Runs a child process and collects its output.
///
/// Everything goes through temporary files rather than pipes: a `Pipe` that is
/// only drained after `waitUntilExit` deadlocks as soon as the child fills the
/// buffer, and transcripts are far larger than that buffer.
public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        public let standardOutput: String
        public let standardError: String

        public var succeeded: Bool { status == 0 }
        public var combined: String { standardOutput + standardError }
    }

    public static func path(of executable: String, in directories: [String] = []) -> String? {
        let searched =
            directories + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init)
                ?? [])
        return searched
            .map { $0 + "/" + executable }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func run(
        _ executable: String, _ arguments: [String], input: String? = nil, directory: URL? = nil
    ) throws -> Result {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("slack-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = try handle(scratch.appendingPathComponent("out"))
        process.standardError = try handle(scratch.appendingPathComponent("err"))
        process.standardInput = try input.map { try inputHandle($0, in: scratch) }
            ?? FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            standardOutput: read(scratch.appendingPathComponent("out")),
            standardError: read(scratch.appendingPathComponent("err"))
        )
    }

    private static func handle(_ url: URL) throws -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }

    private static func inputHandle(_ text: String, in scratch: URL) throws -> FileHandle {
        let url = scratch.appendingPathComponent("in")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try FileHandle(forReadingFrom: url)
    }

    private static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
