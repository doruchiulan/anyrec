import AnyRecKit

enum MicrophoneChoice: Hashable {
    case systemDefault
    case off
    case device(AudioInputDevice)
}

extension RecordingController {
    var microphoneChoice: MicrophoneChoice {
        get {
            if configuration.followsDefaultMicrophone { return .systemDefault }
            return configuration.microphone.map(MicrophoneChoice.device) ?? .off
        }
        set {
            switch newValue {
            case .systemDefault:
                configuration.microphone = nil
                configuration.pinDefaultMicrophone(from: microphones)
                Preferences.followDefaultMicrophone()
            case .off:
                microphone = nil
            case .device(let device):
                microphone = device
            }
        }
    }
}

extension Wording {
    static func systemDefaultMicrophone(_ current: AudioInputDevice?) -> String {
        current.map { "System default (\($0.name))" } ?? "System default"
    }
}
