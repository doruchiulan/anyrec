import Testing

@testable import AnyRecKit

@Suite("MuteButton")
struct MuteButtonTests {
    private let teams = CallApps.known.first { $0.bundleID == "com.microsoft.teams2" }!.muteButton!

    @Test("reads Teams's button as it was seen in a meeting")
    func teamsLabels() {
        #expect(teams.state(of: "Unmute mic") == true)
        #expect(teams.state(of: "Mute mic") == false)
        #expect(teams.state(of: "Audio settings") == nil)
    }

    @Test("reads Slack's huddle button, and not the channel's mute checkbox")
    func slackLabels() {
        let slack = CallApps.known.first { $0.bundleID == "com.tinyspeck.slackmacgap" }!.muteButton!

        #expect(slack.state(of: "Unmute microphone") == true)
        #expect(slack.state(of: "Mute microphone") == false)
        #expect(slack.state(of: "Mute conversation") == nil)
    }

    @Test("matches a label with the shortcut appended, and not the other state")
    func prefix() {
        let meet = MuteButton(muted: "Turn on microphone", live: "Turn off microphone")

        #expect(meet.state(of: "Turn on microphone (⌘+d)") == true)
        #expect(meet.state(of: "Turn off microphone (⌘+d)") == false)
    }

    @Test("watches every known app plus the one recording, buttons where it has them")
    func watchList() {
        let apps = CallApps.watchList(including: "com.example.calls")

        #expect(apps["com.microsoft.teams2"] == .some(teams))
        #expect(apps["us.zoom.xos"] == .some(nil))
        #expect(apps["com.example.calls"] == .some(nil))
        #expect(CallApps.watchList(including: nil).count == CallApps.known.count)
    }
}
