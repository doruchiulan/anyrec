import Foundation
import Testing
@testable import AnyRecBar
@testable import AnyRecKit

@Suite("Preferences", .serialized)
struct PreferencesTests {
    @Test("echo cancellation is on by default and survives a relaunch switched off")
    func echoCancellation() {
        var saved = RecordingConfiguration()
        Preferences.loaded(into: &saved)
        defer { Preferences.save(saved) }

        UserDefaults.standard.removeObject(forKey: "echoCancellation")
        var fresh = RecordingConfiguration()
        fresh.echoCancellation = false
        Preferences.loaded(into: &fresh)
        #expect(fresh.echoCancellation)

        var off = RecordingConfiguration()
        off.echoCancellation = false
        Preferences.save(off)
        var relaunched = RecordingConfiguration()
        Preferences.loaded(into: &relaunched)
        #expect(!relaunched.echoCancellation)
    }
}
