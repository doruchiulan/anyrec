import Testing

@testable import AnyRecKit

@Suite("CaptureCatalogue")
struct CaptureCatalogueTests {
    private func window(_ application: String, _ bundleID: String) -> WindowInfo {
        WindowInfo(
            id: 1, title: "Huddle", application: application, bundleID: bundleID,
            width: 1_280, height: 720)
    }

    @Test("offers call apps' windows before everything else")
    func callAppsComeFirst() {
        let sorted = CaptureCatalogue.callAppsFirst([
            window("Preview", "com.apple.Preview"),
            window("Slack", "com.tinyspeck.slackmacgap"),
        ])

        #expect(sorted.map(\.application) == ["Slack", "Preview"])
    }

    @Test("orders the rest by name, so the list does not shuffle between openings")
    func othersAreAlphabetical() {
        let sorted = CaptureCatalogue.callAppsFirst([
            window("Xcode", "com.apple.dt.Xcode"),
            window("Notes", "com.apple.Notes"),
        ])

        #expect(sorted.map(\.application) == ["Notes", "Xcode"])
    }
}

@Suite("AppleSpeech")
struct AppleSpeechTests {
    @Test("names the languages rather than listing their codes")
    func describesLanguages() {
        let described = AppleSpeech.describe(["fr", "en"])

        #expect(described.split(separator: ", ").count == 2)
        #expect(described != "en, fr")
    }
}
