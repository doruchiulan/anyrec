import Foundation

public enum Defaults {
    public static let outputRoot = "~/Desktop/AnyRec Recordings"
}

/// A window or a display, with the name to show for it.
public struct CaptureChoice: Sendable, Hashable {
    public let target: CaptureTarget
    public let label: String
    public let ownerPID: pid_t?

    public init(target: CaptureTarget, label: String? = nil, ownerPID: pid_t? = nil) {
        self.target = target
        self.label = label ?? Self.describe(target)
        self.ownerPID = ownerPID
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
    /// Nil means the microphone is not recorded. A device picked by hand is kept for the
    /// whole recording while it is connected; the system default, pinned here as a
    /// starting point, is followed when the default changes (`followsDefaultMicrophone`).
    public var microphone: AudioInputDevice?
    /// The microphone was filled in from the system default rather than picked, so a
    /// recording follows the default input when it changes mid-call: switch the call to
    /// AirPods and the microphone track switches with it. Set by `pinDefaultMicrophone`,
    /// cleared by `selectMicrophone` and by any interface that writes a picked device.
    public var followsDefaultMicrophone = false
    public var systemAudio = true
    public var stopAfter: TimeInterval?
    public var mux = true
    /// Nil means no transcript is produced.
    public var transcribe: TranscriptionEngine?
    /// Review and comparison for the transcript; nil runs the chosen engine alone.
    public var transcription: TranscriptionOptions?
    /// A summary after the transcript; nil writes none. Sends the transcript's text to
    /// the provider.
    public var summary: SummaryRequest?
    public var fps = 30
    public var codec: VideoCodec = .h264
    public var showsCursor = true
    /// Off, the recording is audio only: a window or display is still picked — its filter
    /// carries the audio, and its title, call participants and mute button are read as
    /// usual — but no `screen.mov` is written. A choice made per recording, never kept.
    public var video = true
    /// Record the microphone a second time through macOS voice processing, echo cancelled,
    /// beside the raw track; the mixes and attribution use it when it carries sound.
    public var echoCancellation = false
    public var outputRoot: String

    /// What each interface offers for the two settings that are a choice from a list
    /// rather than a free value. Held here so a menu and a cycling row cannot come to
    /// offer different things.
    public static let stopChoices: [TimeInterval?] = [nil, 900, 1_800, 2_700, 3_600, 7_200]
    public static let transcribeChoices: [TranscriptionEngine?] =
        [nil] + TranscriptionEngine.allCases

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
            followsDefaultMicrophone: followsDefaultMicrophone,
            showsCursor: showsCursor,
            recordsVideo: video,
            cleanMicrophone: echoCancellation
        )
    }

    /// False only for an audio-only recording with both audio tracks off, which would
    /// write nothing at all.
    public var recordsAnything: Bool { video || systemAudio || microphone != nil }

    public var outputDirectory: URL { URL(filePath: outputRoot.expandingTilde) }

    /// The system default is only a starting point: it fills an unset microphone so every
    /// interface shows a device, and marks it as followed, so a recording moves with the
    /// default input when the call does. It only ever fills an unset microphone, so
    /// running it after someone has chosen "off" would not undo them — but there is no
    /// reason to.
    ///
    /// Callers that have just listed the inputs pass them back in. Enumerating twice
    /// risks pinning a device that differs from the listed one by more than its id —
    /// `isDefault` moves when a headset connects — and a menu matching on the whole
    /// value then finds no row for the selection and draws itself empty.
    public mutating func pinDefaultMicrophone(from inputs: [AudioInputDevice]? = nil) {
        guard microphone == nil else { return }
        let inputs = inputs ?? AudioDevices.inputs()
        microphone = inputs.first(where: \.isDefault) ?? inputs.first
        followsDefaultMicrophone = microphone != nil
    }

    /// False when no input device carries that id, which is worth saying rather than
    /// silently recording whatever was default.
    public mutating func selectMicrophone(id: String) -> Bool {
        guard let device = AudioDevices.inputs().first(where: { $0.id == id }) else { return false }
        microphone = device
        followsDefaultMicrophone = false
        return true
    }
}
