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
    public var showsCursor: Bool

    public init(
        fps: Int = 30,
        codec: VideoCodec = .h264,
        captureSystemAudio: Bool = true,
        captureMicrophone: Bool = true,
        microphoneDeviceID: String? = nil,
        showsCursor: Bool = true
    ) {
        self.fps = max(1, min(fps, 60))
        self.codec = codec
        self.captureSystemAudio = captureSystemAudio
        self.captureMicrophone = captureMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.showsCursor = showsCursor
    }
}
