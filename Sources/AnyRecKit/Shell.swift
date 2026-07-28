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

    /// `onOutput` is handed each line as the child writes it, for the long-running
    /// children whose output is the only sign they are still working. Without it the
    /// call simply waits.
    public static func run(
        _ executable: String, _ arguments: [String], input: String? = nil, directory: URL? = nil,
        environment: [String: String] = [:], onOutput: ((String) -> Void)? = nil
    ) throws -> Result {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("anyrec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let out = scratch.appendingPathComponent("out")
        let err = scratch.appendingPathComponent("err")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = try handle(out)
        process.standardError = try handle(err)
        process.standardInput = try input.map { try inputHandle($0, in: scratch) }
            ?? FileHandle.nullDevice
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }

        try process.run()
        if let onOutput {
            follow(process, out, err, onOutput)
        } else {
            process.waitUntilExit()
        }

        return Result(
            status: process.terminationStatus,
            standardOutput: read(out),
            standardError: read(err)
        )
    }

    /// Polls the two output files rather than draining pipes, for the same reason
    /// everything else here does: a pipe the child fills while nobody reads deadlocks.
    private static func follow(
        _ process: Process, _ out: URL, _ err: URL, _ onOutput: (String) -> Void
    ) {
        var tails = [Tail(url: out), Tail(url: err)]
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.1)
            for index in tails.indices { tails[index].fresh().forEach(onOutput) }
        }
        process.waitUntilExit()
        for index in tails.indices { tails[index].fresh().forEach(onOutput) }
    }

    /// Lines a file has grown since it was last read. Carriage returns count as line
    /// endings: a progress bar redrawing itself in place is exactly what is wanted here.
    struct Tail {
        let url: URL
        private var consumed = 0

        init(url: URL) { self.url = url }

        mutating func fresh() -> [String] {
            let text = read(url)
            guard text.count > consumed else { return [] }
            let grown = text.dropFirst(consumed)
            guard let last = grown.lastIndex(where: \.isEndOfLine) else { return [] }
            consumed += grown.distance(from: grown.startIndex, to: last) + 1
            return grown[..<last].split(whereSeparator: \.isEndOfLine).map(String.init)
        }
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

extension Character {
    fileprivate var isEndOfLine: Bool { self == "\n" || self == "\r" }
}
