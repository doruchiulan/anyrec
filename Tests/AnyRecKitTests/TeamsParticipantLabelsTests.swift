import Testing
@testable import AnyRecKit

@Suite("Teams participant tiles")
struct TeamsParticipantLabelsTests {
    // Labels and hierarchy captured from Teams on 2026-11-04; local name replaced.
    private var capturedCall: ParticipantLabels.Node {
        .init(children: [
            .init(role: "AXButton", labels: ["Unmute mic"]),
            .init(labels: ["Shared content view"], children: [
                .init(role: "AXImage", labels: ["Myself video, Local Person, Muted, Has context menu"]),
                .init(children: [
                    .init(labels: ["External Test Unverified, muted, Context menu is available"], children: [
                        .init(children: [
                            .init(role: "AXStaticText", labels: ["External Test"]),
                            .init(labels: ["Unverified"]),
                            .init(role: "AXPopUpButton", labels: ["More options"]),
                        ]),
                    ]),
                ]),
            ]),
        ])
    }

    @Test("Visible muted tiles provide names without a participants pane or speech")
    func capturedMutedTiles() {
        let result = ParticipantLabels.parse(capturedCall, platform: .teams)
        #expect(result.participants == ["External Test", "Local Person"])
        #expect(result.speaking.isEmpty)
        #expect(result.hasCallControls)
    }

    @Test("An unmuted tile is a participant, not evidence of speech")
    func unmutedTile() {
        let root = ParticipantLabels.Node(labels: ["Shared content view"], children: [
            .init(labels: ["External Test Unverified, Context menu is available"], children: [
                .init(labels: ["Unverified"]),
            ]),
        ])
        let result = ParticipantLabels.parse(root, platform: .teams)
        #expect(result.participants == ["External Test"])
        #expect(result.speaking.isEmpty)
    }

    @Test("Tile-like text outside the meeting stage cannot add participants")
    func unrelatedText() {
        let root = ParticipantLabels.Node(children: capturedCall.children[1].children)
        #expect(ParticipantLabels.parse(root, platform: .teams).participants.isEmpty)
        #expect(ParticipantLabels.parse(capturedCall, platform: .slack).participants.isEmpty)
    }

    @Test("Names retain commas and badge-like surnames without a badge")
    func exactNames() {
        let root = ParticipantLabels.Node(labels: ["Shared content view"], children: [
            .init(labels: ["Smith, Alex, muted, Context menu is available"]),
            .init(labels: ["Alex Guest, Context menu is available"]),
            .init(role: "AXStaticText", labels: ["Fake, Context menu is available"]),
        ])
        let result = ParticipantLabels.parse(root, platform: .teams)
        #expect(result.participants == ["Alex Guest", "Smith, Alex"])
    }

    @Test("The live Teams border identifies only the containing participant")
    func speakingBorder() {
        let silent = ParticipantLabels.Node(role: "AXGroup", classes: ["fui-Flex"])
        let speaking = ParticipantLabels.Node(role: "AXGroup", classes: ["fui-Flex", "vdi-frame-occlusion"])
        for frame in [silent, speaking, silent] {
            let root = ParticipantLabels.Node(labels: ["Shared content view"], children: [
                .init(role: "AXMenuItem", labels: ["External Test Unverified, Context menu is available"], children: [
                    .init(labels: ["Unverified"]), frame,
                ]),
                .init(role: "AXMenuItem", labels: ["Other Person, Context menu is available"]),
            ])
            let result = ParticipantLabels.parse(root, platform: .teams)
            #expect(result.participants == ["External Test", "Other Person"])
            #expect(result.speaking == (frame.classes.contains("vdi-frame-occlusion") ? ["External Test"] : []))
        }
    }

    @Test("Unrelated borders and stale borders on muted tiles cannot name a speaker")
    func unrelatedBorders() {
        var root = capturedCall
        root.children.append(.init(classes: ["vdi-frame-occlusion"]))
        root.children[1].children[1].children[0].children.append(.init(classes: ["vdi-frame-occlusion"]))
        #expect(ParticipantLabels.parse(root, platform: .teams).speaking.isEmpty)
    }
}
