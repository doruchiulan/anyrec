import Foundation

enum ParticipantLabels {
    enum Platform: String {
        case slack, teams

        init?(bundleID: String) {
            switch bundleID {
            case "com.tinyspeck.slackmacgap": self = .slack
            case "com.microsoft.teams", "com.microsoft.teams2": self = .teams
            default: return nil
            }
        }
    }

    struct Node {
        var role = ""
        var labels: [String] = []
        var identifier = ""
        var classes: [String] = []
        var children: [Node] = []
    }

    struct Snapshot: Equatable {
        var participants: [String]
        var speaking: [String]
        var hasCallControls: Bool
        /// The recording person's own tile, when the app labels it as such.
        var me: String? = nil
    }

    static func parse(_ root: Node, platform: Platform) -> Snapshot {
        let teams = platform == .teams ? TeamsParticipantLabels.read(root)
            : (names: Set<String>(), speaking: Set<String>(), me: nil)
        var names = teams.names, speakers = teams.speaking
        var controls = false
        func visit(_ node: Node) {
            if node.role == "AXButton", node.labels.contains(where: isMuteControl) { controls = true }
            for label in node.labels {
                if let name = speakingName(label) { names.insert(name); speakers.insert(name) }
                if platform == .slack { names.formUnion(profileNames(label)) }
            }
            if platform == .slack, node.classes.contains("p-huddle_peer_tile") {
                let tileNames = descendantNames(node)
                names.formUnion(tileNames)
                if tileNames.count == 1, containsActiveIndicator(node) { speakers.formUnion(tileNames) }
            }
            node.children.forEach(visit)
        }
        visit(root)
        return Snapshot(participants: names.sorted(), speaking: speakers.sorted(), hasCallControls: controls, me: teams.me)
    }

    private static func descendantNames(_ node: Node) -> Set<String> {
        Set(node.labels.flatMap(profileNames)).union(node.children.flatMap { descendantNames($0) })
    }

    private static func containsActiveIndicator(_ node: Node) -> Bool {
        node.classes.contains("p-huddle_peer_tile__overlay--active_speaker")
            || node.children.contains(where: containsActiveIndicator)
    }

    static func speakingName(_ label: String) -> String? {
        guard label.hasSuffix(" is speaking") else { return nil }
        let name = String(label.dropLast(" is speaking".count))
        guard name.lowercased() != "nobody" else { return nil }
        return clean(name)
    }

    /// Slack's profile buttons read "View Alex's profile". A tile can carry two of them in
    /// one label — "View Alex's profile View Sam's profile" — which is two people, never
    /// one called "Alex's profile View Sam".
    static func profileNames(_ label: String) -> [String] {
        var names: [String] = []
        var rest = Substring(label)
        while let view = rest.range(of: "View "), let end = rest[view.upperBound...].range(of: "'s profile") {
            if let name = clean(String(rest[view.upperBound..<end.lowerBound])), !name.contains("'s profile") {
                names.append(name)
            }
            rest = rest[end.upperBound...]
        }
        return names
    }

    /// States Teams appends to a tile's label after the name, comma-separated. Only whole
    /// trailing segments are taken off, so "Smith, Alex" keeps its comma.
    static let teamsStates: Set<String> = [
        "has control of production tools", "unmuted", "muted", "context menu is available", "has context menu",
        "pinned", "spotlighted", "hand raised", "raised hand", "presenting", "speaking", "organizer",
        "organiser", "presenter", "attendee", "video is on", "video is off", "camera is on", "camera is off",
    ]

    static func teamsName(_ value: String) -> String {
        var segments = value.components(separatedBy: ", ")
        while segments.count > 1, teamsStates.contains(segments.last!.trimmingCharacters(in: .whitespaces).lowercased()) {
            segments.removeLast()
        }
        var name = segments.joined(separator: ", ")
        for badge in [" External unfamiliar", " (External)"] where name.hasSuffix(badge) {
            name = String(name.dropLast(badge.count))
        }
        return name
    }

    /// A name as it was stored by an older reader, made what the current one would have
    /// read: Teams' trailing states and badge taken off, Slack's run-together profiles
    /// split apart. Empty when nothing in it is a name.
    static func stored(_ value: String, platform: Platform?) -> [String] {
        let pieces: [String]
        if value.contains("'s profile View ") {
            pieces = profileNames("View " + value + "'s profile")
        } else {
            pieces = [value]
        }
        return pieces.compactMap { piece in clean(platform == .slack ? piece : teamsName(piece)) }
    }

    static func clean(_ value: String) -> String? {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" (Guest)", " (Unverified)"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        guard !name.isEmpty, name.count <= 120, !name.contains("\n"),
              !["you", "me"].contains(name.lowercased()) else { return nil }
        return name
    }

    private static func isMuteControl(_ label: String) -> Bool {
        ["Mute microphone", "Unmute microphone", "Mute mic", "Unmute mic"].contains { label.hasPrefix($0) }
    }
}
