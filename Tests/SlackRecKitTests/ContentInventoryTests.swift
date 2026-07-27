import Testing

@testable import SlackRecKit

@Suite("ContentInventory")
struct ContentInventoryTests {
    @Test("lists a multi-process app once, not once per helper")
    func dedupesHelperProcesses() {
        let apps = ContentInventory.summarise(
            apps: [
                ("com.google.Chrome", "Google Chrome"),
                ("com.google.Chrome", "Google Chrome"),
                ("com.google.Chrome", "Google Chrome"),
            ],
            windowCounts: ["com.google.Chrome": 3]
        )

        #expect(apps.count == 1)
        #expect(apps[0].windowCount == 3)
    }

    @Test("counts windows per app, not per process")
    func countsSurviveDeduping() {
        let apps = ContentInventory.summarise(
            apps: [
                ("com.tinyspeck.slackmacgap", "Slack"),
                ("com.tinyspeck.slackmacgap", "Slack"),
                ("com.apple.Safari", "Safari"),
            ],
            windowCounts: ["com.tinyspeck.slackmacgap": 2, "com.apple.Safari": 1]
        )
        let counts = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0.windowCount) })
        #expect(counts == ["com.tinyspeck.slackmacgap": 2, "com.apple.Safari": 1])
    }

    @Test("drops apps with no capturable window")
    func dropsWindowless() {
        let apps = ContentInventory.summarise(
            apps: [("com.apple.finder", "Finder"), ("com.tinyspeck.slackmacgap", "Slack")],
            windowCounts: ["com.tinyspeck.slackmacgap": 1]
        )
        #expect(apps.map(\.bundleID) == ["com.tinyspeck.slackmacgap"])
    }

    @Test("drops entries ScreenCaptureKit could not name")
    func dropsNameless() {
        let apps = ContentInventory.summarise(
            apps: [("com.example.ghost", ""), ("", "No bundle id")],
            windowCounts: ["com.example.ghost": 1, "": 1]
        )
        #expect(apps.isEmpty)
    }

    @Test("puts call apps first, then sorts by name")
    func callAppsFirst() {
        let apps = ContentInventory.summarise(
            apps: [
                ("com.apple.Safari", "Safari"),
                ("com.tinyspeck.slackmacgap", "Slack"),
                ("com.figma.Desktop", "Figma"),
            ],
            windowCounts: [
                "com.apple.Safari": 1, "com.tinyspeck.slackmacgap": 1, "com.figma.Desktop": 1,
            ]
        )
        #expect(apps.map(\.name) == ["Safari", "Slack", "Figma"])
        #expect(apps.map(\.isKnownCallApp) == [true, true, false])
    }
}
