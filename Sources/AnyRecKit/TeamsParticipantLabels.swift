import Foundation

enum TeamsParticipantLabels {
    static func read(_ root: ParticipantLabels.Node) -> (names: Set<String>, speaking: Set<String>) {
        var names = Set<String>(), speaking = Set<String>()
        func visit(_ node: ParticipantLabels.Node, inTiles: Bool) {
            let inTiles = inTiles || node.labels.contains("Shared content view")
            if inTiles, !["AXStaticText", "AXTextField", "AXTextArea"].contains(node.role) {
                let tileNames = Set(node.labels.compactMap { tileName($0, node: node) })
                names.formUnion(tileNames)
                if tileNames.count == 1, hasSpeakingBorder(node) { speaking.formUnion(tileNames) }
            }
            for child in node.children { visit(child, inTiles: inTiles) }
        }
        visit(root, inTiles: false)
        return (names, speaking)
    }

    private static func hasSpeakingBorder(_ node: ParticipantLabels.Node) -> Bool {
        guard !node.labels.contains(where: { $0.hasPrefix("Myself video, ") || $0.hasSuffix(", muted, Context menu is available") })
        else { return false }
        return containsFrame(node)
    }

    private static func containsFrame(_ node: ParticipantLabels.Node) -> Bool {
        // Teams toggles this class on the speaking border; generated styling classes vary by build.
        node.classes.contains("vdi-frame-occlusion") || node.children.contains(where: containsFrame)
    }

    private static func tileName(_ label: String, node: ParticipantLabels.Node) -> String? {
        var name: String
        if label.hasSuffix(", Context menu is available") {
            name = String(label.dropLast(", Context menu is available".count))
        } else if node.role == "AXImage", label.hasPrefix("Myself video, "), label.hasSuffix(", Has context menu") {
            name = String(label.dropFirst("Myself video, ".count).dropLast(", Has context menu".count))
        } else {
            return nil
        }
        for suffix in [", muted", ", Muted"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        for badge in ["Unverified", "Guest"] where name.hasSuffix(" " + badge) && contains(badge, in: node) {
            name = String(name.dropLast(badge.count + 1))
        }
        return ParticipantLabels.clean(name)
    }

    private static func contains(_ label: String, in node: ParticipantLabels.Node) -> Bool {
        node.labels.contains(label) || node.children.contains { contains(label, in: $0) }
    }
}
