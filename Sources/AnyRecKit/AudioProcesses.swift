import CoreAudio
import Foundation

/// A process Core Audio knows about, and whether it is running audio in or out.
public struct AudioProcess: Sendable, Equatable {
    public let bundleID: String
    public let pid: pid_t
    public let runningInput: Bool
    public let runningOutput: Bool
}

/// Who is doing audio right now, read from the HAL's process objects. This is the
/// list behind the orange dot: it needs no permission and hears nothing.
public enum AudioProcesses {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    public static func snapshot() -> [AudioProcess] {
        objects().compactMap { object in
            guard let input = number(object, kAudioProcessPropertyIsRunningInput),
                let output = number(object, kAudioProcessPropertyIsRunningOutput)
            else { return nil }
            return AudioProcess(
                bundleID: bundleID(of: object),
                pid: pid_t(bitPattern: number(object, kAudioProcessPropertyPID) ?? 0),
                runningInput: input != 0,
                runningOutput: output != 0
            )
        }
    }

    private static func objects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func number(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    /// Empty for a process without a bundle, such as a command-line tool.
    private static func bundleID(of object: AudioObjectID) -> String {
        var address = address(kAudioProcessPropertyBundleID)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var string: Unmanaged<CFString>? = nil
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &string) == noErr,
            let string
        else { return "" }
        return string.takeRetainedValue() as String
    }

    private static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}
