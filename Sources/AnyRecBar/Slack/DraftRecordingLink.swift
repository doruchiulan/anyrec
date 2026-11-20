import Foundation

enum DraftRecordingLink {
    static func parse(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let url = URL(string: value, encodingInvalidCharacters: false),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func read(_ file: URL) -> URL? {
        (try? String(contentsOf: file, encoding: .utf8)).flatMap(parse)
    }

    static func save(_ link: URL?, at file: URL) throws {
        let fm = FileManager.default
        if let link {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try link.absoluteString.write(to: file, atomically: true, encoding: .utf8)
        } else if fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
        }
    }

    static func message(_ text: String, link: URL?, audioOnly: Bool) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let link else { return body }
        return body + "\n\n" + (audioOnly ? "Audio" : "Recording") + "\n" + link.absoluteString
    }
}
