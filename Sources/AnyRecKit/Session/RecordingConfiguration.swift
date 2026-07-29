import Foundation

public enum Defaults {
    public static let outputRoot = "~/Desktop/AnyRec Recordings"
}

/// A window or a display, with the name to show for it.
public struct CaptureChoice: Sendable, Equatable {
    public let target: CaptureTarget
    public let label: String

    public init(target: CaptureTarget, label: String? = nil) {
        self.target = target
        self.label = label ?? Self.describe(target)
    }

    private static func describe(_ target: CaptureTarget) -> String {
        switch target {
        case .display(let index): "Display \(index)"
        case .window(let id): "Window \(id)"
        }
    }
}

/// What a recording is, before it starts. Every interface edits one of these and none
/// of them owns it, so a window picked in a menu bar records what the same window
/// picked in the terminal would.
public struct RecordingConfiguration: Sendable {
    /// Nil until a window or display is picked: recording the wrong thing is worse
    /// than recording nothing, so there is no default.
    public var capture: CaptureChoice?
    /// Nil means the microphone is not recorded. The device is always explicit, so
    /// another app switching the system default mid-call cannot redirect the capture.
    public var microphone: AudioInputDevice?
    public var systemAudio = true
    public var stopAfter: TimeInterval?
    public var mux = true
    /// Nil means no transcript is produced.
    public var transcribe: TranscriptionEngine?
    public var fps = 30
    public var codec: VideoCodec = .h264
    public var showsCursor = true
    public var outputRoot: String

    public init(outputRoot: String = Defaults.outputRoot) {
        self.outputRoot = outputRoot
    }

    public var options: CaptureOptions {
        CaptureOptions(
            fps: fps,
            codec: codec,
            captureSystemAudio: systemAudio,
            captureMicrophone: microphone != nil,
            microphoneDeviceID: microphone?.id,
            showsCursor: showsCursor
        )
    }

    public var outputDirectory: URL { URL(filePath: outputRoot.expandingTilde) }

    /// The system default is only a starting point; it is pinned as an explicit device
    /// so another app changing the default mid-call cannot redirect the capture. It
    /// only ever fills an unset microphone, so running it after someone has chosen
    /// "off" would not undo them — but there is no reason to.
    public mutating func pinDefaultMicrophone() {
        guard microphone == nil else { return }
        let inputs = AudioDevices.inputs()
        microphone = inputs.first(where: \.isDefault) ?? inputs.first
    }

    /// False when no input device carries that id, which is worth saying rather than
    /// silently recording whatever was default.
    public mutating func selectMicrophone(id: String) -> Bool {
        guard let device = AudioDevices.inputs().first(where: { $0.id == id }) else { return false }
        microphone = device
        return true
    }
}
