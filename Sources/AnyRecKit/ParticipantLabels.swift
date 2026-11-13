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
    }

    static func parse(_ root: Node, platform: Platform) -> Snapshot {
        let teams = platform == .teams ? TeamsParticipantLabels.read(root) : (names: Set<String>(), speaking: Set<String>())
        var names = teams.names, speakers = teams.speaking
        var controls = false
        func visit(_ node: Node) {
            if node.role == "AXButton", node.labels.contains(where: isMuteControl) { controls = true }
            for label in node.labels {
                if let name = speakingName(label) { names.insert(name); speakers.insert(name) }
                if platform == .slack, let name = profileName(label) { names.insert(name) }
            }
            if platform == .slack, node.classes.contains("p-huddle_peer_tile") {
                let tileNames = descendantNames(node)
                names.formUnion(tileNames)
                if tileNames.count == 1, containsActiveIndicator(node) { speakers.formUnion(tileNames) }
            }
            node.children.forEach(visit)
        }
        visit(root)
        return Snapshot(participants: names.sorted(), speaking: speakers.sorted(), hasCallControls: controls)
    }

    private static func descendantNames(_ node: Node) -> Set<String> {
        Set(node.labels.compactMap(profileName)).union(node.children.flatMap { descendantNames($0) })
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

    private static func profileName(_ label: String) -> String? {
        guard label.hasPrefix("View "), label.hasSuffix("'s profile") else { return nil }
        return clean(String(label.dropFirst(5).dropLast(10)))
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
