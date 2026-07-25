import AVFoundation
import Foundation

public struct AudioInputDevice: Sendable, Equatable {
    public let id: String
    public let name: String
    public let isDefault: Bool
}

public enum AudioDevices {
    public static func inputs() -> [AudioInputDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return session.devices.map {
            AudioInputDevice(
                id: $0.uniqueID,
                name: $0.localizedName,
                isDefault: $0.uniqueID == defaultID
            )
        }
    }
}
