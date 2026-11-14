import AppKit
import Foundation

/// Which file in a recording folder plays, which holds the picture, and what the merged
/// file is called. Every reader of a recording's media asks here rather than naming a
/// file itself, because the answer depends on how far the recording has got: `screen.mov`
/// until a merge is verified, then the merged file, named from the recording, alone.
/// Folders from before merged files were named hold `call.mp4` beside `screen.mov`, and
/// read the same way they always did.
public enum RecordingMedia {
    /// What the merge was called before it was named, and still is in older folders and
    /// in folders with no `recording.json` to keep a name in.
    public static let legacyMergedName = "call.mp4"

    /// The merged file: the name `recording.json` keeps when that file is there, else
    /// `call.mp4`. Nil before any merge, and after `--no-mux` or a failed one.
    public static func merged(in directory: URL, info: RecordingInfo?) -> URL? {
        if let name = info?.mergedFile, isPlainName(name) {
            let named = directory.appendingPathComponent(name)
            if exists(named) { return named }
        }
        let legacy = directory.appendingPathComponent(legacyMergedName)
        return exists(legacy) ? legacy : nil
    }

    public static func merged(in directory: URL) -> URL? {
        merged(in: directory, info: RecordingInfo.read(directory))
    }

    /// What plays: the merged file, else `screen.mov`. Nil when neither is there.
    public static func playable(in directory: URL, info: RecordingInfo?) -> URL? {
        if let merged = merged(in: directory, info: info) { return merged }
        let screen = OutputPlan(directory: directory).screen
        return exists(screen) ? screen : nil
    }

    public static func playable(in directory: URL) -> URL? {
        playable(in: directory, info: RecordingInfo.read(directory))
    }

    /// The file holding the recording's picture: `screen.mov` while it exists, else the
    /// merged file that replaced it. Nil for an audio-only recording.
    public static func video(in directory: URL, info: RecordingInfo?) -> URL? {
        guard info?.audioOnly != true else { return nil }
        let screen = OutputPlan(directory: directory).screen
        return exists(screen) ? screen : merged(in: directory, info: info)
    }

    public static func video(in directory: URL) -> URL? {
        video(in: directory, info: RecordingInfo.read(directory))
    }

    // MARK: Naming

    /// The merged file's name for a recording folder: from its `recording.json` and the
    /// time in its folder name. Without a `recording.json` there is nowhere to keep a
    /// name, so the merge stays `call.mp4`, which every reader already finds.
    public static func mergedName(in directory: URL, info: RecordingInfo?, audioOnly: Bool) -> String {
        guard let info else { return legacyMergedName }
        return fileName(title: info.title, app: appName(for: info),
                        started: RecordingLibrary.started(directory), audioOnly: audioOnly)
    }

    /// "Design review – Slack – 2026-11-03 10.08.mp4": the title with its noise taken out,
    /// the app unless the title already is it, and the start in a form with no colons and
    /// no locale in it. `.m4a` when there is no picture.
    public static func fileName(
        title: String, app: String?, started: Date, audioOnly: Bool, timeZone: TimeZone = .current
    ) -> String {
        let app = app.map(sanitized).map { capped($0, bytes: 40) }.flatMap { $0.isEmpty ? nil : $0 }
        let cleaned = capped(sanitized(cleanTitle(title, app: app)), bytes: 120)
        let name = cleaned.isEmpty ? (app ?? "Recording") : cleaned
        var parts = [name]
        if let app, app.caseInsensitiveCompare(name) != .orderedSame { parts.append(app) }
        parts.append(stamp(started, timeZone: timeZone))
        return parts.joined(separator: " – ") + (audioOnly ? ".m4a" : ".mp4")
    }

    /// The app's name: the registry's, else the installed bundle's own, else none.
    static func appName(for info: RecordingInfo) -> String? {
        if let known = info.appName { return known }
        guard let id = info.bundleID,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: date)
    }

    /// What the window's title says that is not what the call is: a trailing segment that
    /// is the app ("… - Slack"), unread counters ("2 new items"), a browser's "(3) "
    /// badge, and the labels `TargetResolver` gives a display or an untitled window.
    /// Slack's workspace segment is kept: nothing in the title marks which segment it is.
    static func cleanTitle(_ title: String, app: String?) -> String {
        var title = collapsed(title).filter { !isInvisible($0) }
        if title.range(of: #"^(display|window) \d+$"#, options: .regularExpression) != nil {
            return title.hasPrefix("display") ? "Display" : ""
        }
        if let badge = title.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) {
            title.removeSubrange(badge)
        }
        var segments = title.split(separator: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isCounter($0) }
        if segments.count > 1, let last = segments.last, let app, isApp(last, app) {
            segments.removeLast()
        }
        return segments.joined(separator: " - ")
    }

    /// Spaced hyphens, dashes and bars: how apps join the parts of a window title.
    /// A hyphen inside a name ("Ana-Maria") has no spaces around it and is left alone.
    nonisolated(unsafe) private static let separator = #/\s+[-–—|]\s+/#

    private static func isCounter(_ segment: String) -> Bool {
        segment.range(of: #"^\d+ new (items?|messages?)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "Slack" for Slack; "Google Chrome" for Chrome; "Microsoft Teams" for the classic
    /// client, whose registry name carries "(classic)".
    private static func isApp(_ segment: String, _ app: String) -> Bool {
        let bare = app.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
        return [app, bare].contains { name in
            segment.caseInsensitiveCompare(name) == .orderedSame
                || (segment.lowercased().hasSuffix(" " + name.lowercased())
                    && segment.split(separator: " ").count <= name.split(separator: " ").count + 1)
        }
    }

    /// Safe in Finder, in a zip, on a share and on Windows: no path separators or colons
    /// (Finder shows ":" as "/"), none of the characters Windows refuses, no control or
    /// invisible characters, no leading dot (hidden) or dash (read as an option by a
    /// command line), and no trailing dot or space.
    static func sanitized(_ text: String) -> String {
        var out = ""
        for character in collapsed(text).precomposedStringWithCanonicalMapping where !isInvisible(character) {
            switch character {
            case "/", "\\", ":", "|": out.append("-")
            case "<", ">", "\"", "?", "*": continue
            default: out.append(character)
            }
        }
        out = collapsed(out)
        while let first = out.first, " .-–".contains(first) { out.removeFirst() }
        while let last = out.last, " .-–".contains(last) { out.removeLast() }
        return out
    }

    /// Cut at a character boundary to fit the bytes; a cut name ends in "…" and never on
    /// a dangling separator.
    static func capped(_ text: String, bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var out = ""
        for character in text {
            if (out + String(character)).utf8.count > limit - "…".utf8.count { break }
            out.append(character)
        }
        while let last = out.last, " -–.,".contains(last) { out.removeLast() }
        return out + "…"
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Control characters and the format characters a title can carry unseen — Edge puts
    /// a zero-width space inside its own name.
    private static func isInvisible(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
        }
    }

    /// A name read back from `recording.json` is only ever a file in the folder.
    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/")
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
