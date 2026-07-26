import Foundation

/// Which track a line came from. The microphone and the call are recorded as
/// separate files, so attribution costs nothing: no diarisation is involved.
public enum Speaker: String, Sendable, CaseIterable {
    case me
    case others

    public var label: String {
        switch self {
        case .me: "Me"
        case .others: "Call"
        }
    }
}

public struct Utterance: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var speaker: Speaker

    public init(
        start: TimeInterval, end: TimeInterval, text: String, speaker: Speaker = .others
    ) {
        self.start = start
        self.end = end
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.speaker = speaker
    }
}

public struct Transcript: Sendable, Equatable {
    /// Consecutive lines from one speaker, read as a single turn.
    public struct Turn: Sendable, Equatable {
        public let speaker: Speaker
        public let start: TimeInterval
        public let text: String
    }

    public let utterances: [Utterance]
    public let language: String
    public let engine: String
    /// What the reader has to know before believing the speaker labels.
    public let notes: [String]

    public init(
        utterances: [Utterance], language: String, engine: String, notes: [String] = []
    ) {
        self.utterances =
            utterances
            .filter { !$0.text.isEmpty }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        self.language = language
        self.engine = engine
        self.notes = notes
    }

    public var isEmpty: Bool { utterances.isEmpty }
    public var duration: TimeInterval { utterances.map(\.end).max() ?? 0 }

    public var turns: [Turn] {
        utterances.reduce(into: [Turn]()) { turns, utterance in
            if let last = turns.last, last.speaker == utterance.speaker {
                turns[turns.count - 1] = Turn(
                    speaker: last.speaker, start: last.start, text: last.text + " " + utterance.text
                )
            } else {
                turns.append(
                    Turn(speaker: utterance.speaker, start: utterance.start, text: utterance.text))
            }
        }
    }

    /// Speaker-labelled prose. This is what gets handed to a model for summarising.
    public var plainText: String {
        turns
            .map { "[\(Self.clock($0.start))] \($0.speaker.label): \($0.text)" }
            .joined(separator: "\n\n")
    }

    public func markdown(title: String) -> String {
        let header =
            [
                "# \(title)",
                "",
                "\(Self.clock(duration)) · \(languageName) · transcribed by \(engine)",
                "",
            ] + notes.flatMap { ["> \($0)", ""] }
        let body = turns.map {
            "**[\(Self.clock($0.start))] \($0.speaker.label):** \($0.text)"
        }
        return header.joined(separator: "\n") + "\n" + body.joined(separator: "\n\n") + "\n"
    }

    public var srt: String {
        utterances.enumerated()
            .map { index, utterance in
                """
                \(index + 1)
                \(Self.stamp(utterance.start)) --> \(Self.stamp(utterance.end))
                \(utterance.speaker.label): \(utterance.text)

                """
            }
            .joined(separator: "\n")
    }

    public var languageName: String {
        Locale(identifier: "en_US_POSIX").localizedString(forLanguageCode: language) ?? language
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let (hours, minutes, secs) = (total / 3_600, (total % 3_600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    static func stamp(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let milliseconds = Int((total - total.rounded(.down)) * 1_000)
        let whole = Int(total.rounded(.down))
        return String(
            format: "%02d:%02d:%02d,%03d",
            whole / 3_600, (whole % 3_600) / 60, whole % 60, milliseconds
        )
    }
}
