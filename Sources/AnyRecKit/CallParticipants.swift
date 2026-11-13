import Foundation

public struct CallParticipants: Codable, Equatable, Sendable {
    public struct Observation: Codable, Equatable, Sendable {
        public let at: TimeInterval
        public let source: String
        public let participants: [String]
        public let speaking: [String]
    }

    public static let fileName = "call-participants.json"
    public var observations: [Observation]

    public static func read(in directory: URL) -> Self? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(Self.self, from: data),
              result.observations.allSatisfy({ $0.at.isFinite && $0.at >= 0 }) else { return nil }
        return result
    }

    public func write(in directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    struct Span {
        let start: TimeInterval
        let end: TimeInterval
        let name: String
    }

    var spans: [Span] {
        guard zip(observations, observations.dropFirst()).allSatisfy({ $0.at < $1.at }) else { return [] }
        return zip(observations, observations.dropFirst()).compactMap { first, next in
            // Missing polls and changing indicators provide no evidence between their endpoints.
            guard first.at.isFinite, next.at.isFinite, first.at >= 0,
                  next.at > first.at, next.at - first.at <= 1.5,
                  first.source == next.source, first.speaking == next.speaking,
                  first.speaking.count == 1, let name = first.speaking.first,
                  first.participants.contains(name), next.participants.contains(name) else { return nil }
            return Span(start: first.at, end: next.at, name: name)
        }
    }
}
