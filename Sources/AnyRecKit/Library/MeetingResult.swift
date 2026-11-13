import Foundation

public enum MeetingReadError: Error, LocalizedError {
    case invalid(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message): message
        }
    }
}

public struct MeetingPage<Item: Encodable & Sendable>: Encodable, Sendable {
    public let items: [Item]
    public let nextOffset: Int?
    public var warnings: [String] = []
}

public struct MeetingDetails: Encodable, Sendable {
    public let id: String
    public let title: String
    public let startedAt: Date
    public let app: String?
    public let transcriptAvailable: Bool
    public let summaryAvailable: Bool
    public let transcriptGeneration: String?
    public let participantNames: [String]
    public let warnings: [String]
}

public struct MeetingParticipants: Encodable, Sendable {
    public struct Voice: Encodable, Sendable {
        public let label: String
        public let name: String?
        public let identityEvidence: SpeakerIdentityEvidence?
    }

    public let meetingID: String
    public let observedInCall: [String]
    public let transcriptSpeakers: [Voice]
    public let warnings: [String]

    var names: [String] {
        Array(Set(observedInCall + transcriptSpeakers.compactMap(\.name))).sorted()
    }
}

public struct MeetingTranscript: Encodable, Sendable {
    public struct Line: Encodable, Sendable {
        public let index: Int
        public let start: TimeInterval
        public let end: TimeInterval
        public let speaker: String
        public let speakerName: String?
        public let text: String
    }

    public let meetingID: String
    public let generation: String?
    public let engine: String
    public let language: String?
    public let notes: [String]
    public let lines: [Line]
    public let nextOffset: Int?
    public let warnings: [String]
}

public struct MeetingSummary: Encodable, Sendable {
    public let meetingID: String
    public let generation: String?
    public let summary: Summary?
    public let markdown: String?
    public let warnings: [String]
}

public struct MeetingSearchHit: Encodable, Sendable {
    public let meetingID: String
    public let title: String
    public let field: String
    public let excerpt: String
    public let start: TimeInterval?
    public let end: TimeInterval?
    public let speaker: String?
    public let lineIndex: Int?
}

public struct MeetingFilter: Sendable {
    public var query: String?
    public var participant: String?
    public var after: Date?
    public var before: Date?

    public init(query: String? = nil, participant: String? = nil, after: Date? = nil, before: Date? = nil) {
        self.query = query
        self.participant = participant
        self.after = after
        self.before = before
    }

    func matches(_ meeting: MeetingDetails) -> Bool {
        (query.map { meeting.title.meetingContains($0) } ?? true)
            && (participant.map { name in meeting.participantNames.contains { $0.meetingContains(name) } } ?? true)
            && (after.map { meeting.startedAt >= $0 } ?? true)
            && (before.map { meeting.startedAt < $0 } ?? true)
    }
}

extension String {
    func meetingContains(_ query: String) -> Bool {
        range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) != nil
    }
}
