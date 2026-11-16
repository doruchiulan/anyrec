import AVFoundation
import Foundation

public enum VideoCodec: String, CaseIterable, Sendable {
    case h264
    case hevc

    public var avCodecType: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        }
    }
}

public struct CaptureOptions: Sendable {
    public var fps: Int
    public var codec: VideoCodec
    public var captureSystemAudio: Bool
    public var captureMicrophone: Bool
    public var microphoneDeviceID: String?
    /// The microphone was not picked: it is the system default, and follows the default
    /// when that changes mid-recording. Off, `microphoneDeviceID` is kept while connected.
    public var followsDefaultMicrophone: Bool
    public var showsCursor: Bool
    /// Off, no `screen.mov` is written: the window is still captured for its filter, its
    /// title, its participants and its mute button, but only the audio is kept.
    public var recordsVideo: Bool
    /// Also record the microphone through macOS voice processing, echo cancelled, as
    /// `microphone-clean.m4a`. Only with the microphone on; the raw track is kept either way.
    public var cleanMicrophone: Bool

    public init(
        fps: Int = 30,
        codec: VideoCodec = .h264,
        captureSystemAudio: Bool = true,
        captureMicrophone: Bool = true,
        microphoneDeviceID: String? = nil,
        followsDefaultMicrophone: Bool = false,
        showsCursor: Bool = true,
        recordsVideo: Bool = true,
        cleanMicrophone: Bool = false
    ) {
        self.fps = max(1, min(fps, 60))
        self.codec = codec
        self.captureSystemAudio = captureSystemAudio
        self.captureMicrophone = captureMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.followsDefaultMicrophone = followsDefaultMicrophone
        self.showsCursor = showsCursor
        self.recordsVideo = recordsVideo
        self.cleanMicrophone = cleanMicrophone
    }
}
