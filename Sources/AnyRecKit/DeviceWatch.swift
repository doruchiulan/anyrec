import CoreAudio
import Foundation

/// Tells its owner when the audio devices change: the default input or output moving, or
/// a device connecting or disconnecting. Says nothing about what changed; the owner reads
/// the devices again and decides (`MicrophoneRoute`). Needs no permission.
final class DeviceWatch {
    private static let selectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDevices,
    ]

    private let queue: DispatchQueue
    private var listener: AudioObjectPropertyListenerBlock?

    /// `queue` is where `changed` is called.
    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit { stop() }

    func start(_ changed: @escaping () -> Void) {
        stop()
        let listener: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
        self.listener = listener
    }

    func stop() {
        guard let listener else { return }
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
        self.listener = nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
