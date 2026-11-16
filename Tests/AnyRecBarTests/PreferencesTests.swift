import Foundation
import Testing
@testable import AnyRecBar
@testable import AnyRecKit

@Suite("Preferences", .serialized)
struct PreferencesTests {
    @Test("system default clears a pinned microphone or Off across launches")
    func defaultMicrophone() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "microphoneID")
        defer {
            if let saved { defaults.set(saved, forKey: "microphoneID") }
            else { defaults.removeObject(forKey: "microphoneID") }
        }
        let device = AudioInputDevice(id: "test-usb", name: "USB microphone", isDefault: false)
        let system = AudioInputDevice(id: "test-mac", name: "Built-in microphone", isDefault: true)
        Preferences.saveMicrophone(device)
        #expect(Preferences.microphone(among: [device, system]) == device)

        Preferences.followDefaultMicrophone()
        #expect(defaults.object(forKey: "microphoneID") == nil)
        #expect(!Preferences.microphoneIsOff)
        var relaunched = RecordingConfiguration()
        relaunched.microphone = Preferences.microphone(among: [device, system])
        relaunched.pinDefaultMicrophone(from: [device, system])
        #expect(relaunched.microphone == system)
        #expect(relaunched.followsDefaultMicrophone)

        Preferences.saveMicrophone(nil)
        #expect(Preferences.microphoneIsOff)
        Preferences.followDefaultMicrophone()
        #expect(!Preferences.microphoneIsOff)
        #expect(defaults.object(forKey: "microphoneID") == nil)
    }

    @Test("echo cancellation defaults off and preserves saved choices")
    func echoCancellation() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "echoCancellation")
        var saved = RecordingConfiguration()
        Preferences.loaded(into: &saved)
        defer {
            Preferences.save(saved)
            if let original { defaults.set(original, forKey: "echoCancellation") }
            else { defaults.removeObject(forKey: "echoCancellation") }
        }

        defaults.removeObject(forKey: "echoCancellation")
        var configuration = RecordingConfiguration()
        Preferences.loaded(into: &configuration)
        #expect(!configuration.echoCancellation)

        for enabled in [true, false] {
            configuration.echoCancellation = enabled
            Preferences.save(configuration)
            var relaunched = RecordingConfiguration()
            Preferences.loaded(into: &relaunched)
            #expect(relaunched.echoCancellation == enabled)
        }
    }
}
