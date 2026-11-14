import Foundation

public struct CallParticipants: Codable, Equatable, Sendable {
    public struct Observation: Codable, Equatable, Sendable {
        public let at: TimeInterval
        public let source: String
        public let participants: [String]
        public let speaking: [String]
        /// The recording person's own tile, where the app labels one. Nil in older files.
        public var me: String? = nil

        public init(at: TimeInterval, source: String, participants: [String], speaking: [String], me: String? = nil) {
            self.at = at
            self.source = source
            self.participants = participants
            self.speaking = speaking
            self.me = me
        }

        /// Names as the current parser reads them: a file written by an older one keeps
        /// Teams' states ("…, Has control of production tools") and Slack's run-together
        /// profiles, and the same person must not appear twice.
        func cleaned() -> Observation {
            let platform = ParticipantLabels.Platform(bundleID: String(source.prefix { $0 != ":" }))
            let clean = { (names: [String]) in
                Array(Set(names.flatMap { ParticipantLabels.stored($0, platform: platform) })).sorted()
            }
            return Observation(at: at, source: source, participants: clean(participants), speaking: clean(speaking),
                               me: me.flatMap { ParticipantLabels.stored($0, platform: platform).first })
        }
    }

    public static let fileName = "call-participants.json"
    public var observations: [Observation]

    public static func read(in directory: URL) -> Self? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(Self.self, from: data),
              result.observations.allSatisfy({ $0.at.isFinite && $0.at >= 0 }) else { return nil }
        return CallParticipants(observations: result.observations.map { $0.cleaned() })
    }

    public func write(in directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// A stretch between two polls in which the same people were marked speaking in both.
    /// One name is evidence of who was talking; several are evidence only of who might
    /// have been, which can agree with a name but never supply one.
    struct Span {
        let start: TimeInterval
        let end: TimeInterval
        let names: [String]
    }

    var spans: [Span] {
        guard zip(observations, observations.dropFirst()).allSatisfy({ $0.at < $1.at }) else { return [] }
        return zip(observations, observations.dropFirst()).compactMap { first, next in
            // Missing polls and changing indicators provide no evidence between their endpoints.
            guard first.at.isFinite, next.at.isFinite, first.at >= 0, !first.source.isEmpty,
                  next.at > first.at, next.at - first.at <= 1.5, first.source == next.source else { return nil }
            let names = Set(first.speaking).intersection(next.speaking)
                .filter { first.participants.contains($0) && next.participants.contains($0) }
            guard !names.isEmpty else { return nil }
            return Span(start: first.at, end: next.at, names: names.sorted())
        }
    }

    /// How long the call window could be read: the time between consecutive polls that
    /// both found it, no more than 1.5 s apart.
    public var readable: TimeInterval {
        zip(observations, observations.dropFirst()).reduce(0) { total, pair in
            let (first, next) = pair
            guard !first.source.isEmpty, first.source == next.source, next.at > first.at, next.at - first.at <= 1.5
            else { return total }
            return total + next.at - first.at
        }
    }

    /// Everyone the call window showed, with how long each was marked as the only one
    /// speaking. What the recording's page lists as observed.
    public var roster: [(name: String, speaking: TimeInterval)] {
        var speaking: [String: TimeInterval] = [:]
        for span in spans where span.names.count == 1 { speaking[span.names[0], default: 0] += span.end - span.start }
        let everyone = Set(observations.flatMap(\.participants))
        return everyone.map { ($0, speaking[$0] ?? 0) }.sorted { ($1.speaking, $0.name) < ($0.speaking, $1.name) }
    }

    /// The recording person's own tile names, where the app labelled them.
    var selfNames: Set<String> { Set(observations.compactMap(\.me)) }
}
