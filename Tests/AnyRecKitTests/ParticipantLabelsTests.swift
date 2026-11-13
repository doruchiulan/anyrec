import Testing
@testable import AnyRecKit

@Suite("Meeting accessibility labels")
struct ParticipantLabelsTests {
    private let mute = ParticipantLabels.Node(role: "AXButton", labels: ["Mute microphone"])

    @Test("Slack maps the speaking overlay only to its containing participant tile")
    func slackTiles() {
        let alex = ParticipantLabels.Node(classes: ["p-huddle_peer_tile"], children: [
            .init(role: "AXButton", labels: ["View Alex's profile"]),
            .init(classes: ["p-huddle_peer_tile__overlay--active_speaker"]),
        ])
        let costin = ParticipantLabels.Node(classes: ["p-huddle_peer_tile"], children: [
            .init(role: "AXButton", labels: ["View Costin's profile"]),
        ])
        let result = ParticipantLabels.parse(.init(children: [mute, alex, costin]), platform: .slack)
        #expect(result.participants == ["Alex", "Costin"])
        #expect(result.speaking == ["Alex"])
        #expect(result.hasCallControls)
    }

    @Test("Teams speaking labels remove guest markers and reject Nobody")
    func teamsLabels() {
        let result = ParticipantLabels.parse(.init(children: [mute,
            .init(labels: ["Costin (Guest) is speaking"]), .init(labels: ["Nobody is speaking"]),
        ]), platform: .teams)
        #expect(result.speaking == ["Costin"])
        #expect(result.participants == ["Costin"])
        #expect(ParticipantLabels.speakingName("You is speaking") == nil)
        #expect(ParticipantLabels.speakingName("Alex is speaking about an issue") == nil)
    }

    @Test("Multiple highlighted names remain ambiguous; a profile alone is not speech")
    func ambiguous() {
        let root = ParticipantLabels.Node(classes: ["p-huddle_peer_tile"], children: [mute,
            .init(labels: ["View Alex's profile", "View Costin's profile"]),
            .init(classes: ["p-huddle_peer_tile__overlay--active_speaker"]),
        ])
        #expect(ParticipantLabels.parse(root, platform: .slack).speaking.isEmpty)
        #expect(ParticipantLabels.parse(.init(labels: ["View Alex's profile"]), platform: .slack).speaking.isEmpty)
    }
}
