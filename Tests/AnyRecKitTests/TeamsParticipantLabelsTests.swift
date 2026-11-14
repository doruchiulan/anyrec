import Foundation
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

@Suite("Participant label shapes seen in real calls")
struct ParticipantLabelShapesTests {
    @Test("Teams states after the name are removed, so one person is one participant")
    func teamsStates() {
        let root = ParticipantLabels.Node(labels: ["Shared content view"], children: [
            .init(labels: ["Alex Ionescu, Has control of production tools, Context menu is available"]),
            .init(labels: ["Alex Ionescu, Has control of production tools, Unmuted, Context menu is available"]),
            .init(labels: ["Maria Pop External unfamiliar, Has control of production tools, Context menu is available"]),
            .init(labels: ["Smith, Alex, muted, Context menu is available"]),
        ])
        #expect(ParticipantLabels.parse(root, platform: .teams).participants == ["Alex Ionescu", "Maria Pop", "Smith, Alex"])
    }

    @Test("Teams names the recording person's own tile")
    func ownTile() {
        let root = ParticipantLabels.Node(labels: ["Shared content view"], children: [
            .init(role: "AXImage", labels: ["Myself video, Local Person, Muted, Has context menu"]),
        ])
        #expect(ParticipantLabels.parse(root, platform: .teams).me == "Local Person")
    }

    @Test("Slack labels carrying two profiles are two people")
    func slackRunTogether() {
        let tile = ParticipantLabels.Node(classes: ["p-huddle_peer_tile"], children: [
            .init(role: "AXButton", labels: ["View Alex Ionescu's profile View Maria Pop's profile"]),
        ])
        let root = ParticipantLabels.Node(children: [.init(role: "AXButton", labels: ["Mute microphone"]), tile])
        #expect(ParticipantLabels.parse(root, platform: .slack).participants == ["Alex Ionescu", "Maria Pop"])
        #expect(ParticipantLabels.parse(root, platform: .slack).speaking.isEmpty)
    }

    @Test("Names stored by the older parser are cleaned when read")
    func storedNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-participants-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = CallParticipants(observations: [
            .init(at: 0, source: "com.microsoft.teams2:1:2",
                  participants: ["Alex Ionescu, Has control of production tools",
                                 "Alex Ionescu, Has control of production tools, Unmuted",
                                 "Maria Pop External unfamiliar, Has control of production tools"],
                  speaking: ["Maria Pop External unfamiliar, Has control of production tools"]),
            .init(at: 1, source: "com.tinyspeck.slackmacgap:1:2",
                  participants: ["Alex Ionescu", "Alex Ionescu's profile View Maria Pop", "Maria Pop"], speaking: ["Maria Pop"]),
        ])
        try old.write(in: directory)
        let read = try #require(CallParticipants.read(in: directory))
        #expect(read.observations[0].participants == ["Alex Ionescu", "Maria Pop"])
        #expect(read.observations[0].speaking == ["Maria Pop"])
        #expect(read.observations[1].participants == ["Alex Ionescu", "Maria Pop"])
    }

    @Test("The roster says who was seen, how long each spoke alone, and how long the window could be read")
    func roster() {
        let polls = CallParticipants(observations: (0..<10).map {
            .init(at: Double($0), source: "slack:1:2", participants: ["Alex", "Maria"], speaking: $0 < 6 ? ["Maria"] : [])
        } + [.init(at: 10, source: "", participants: [], speaking: [])])
        #expect(polls.readable == 9)
        #expect(polls.roster.map(\.name) == ["Maria", "Alex"])
        #expect(polls.roster.map(\.speaking) == [5, 0])
    }
}
