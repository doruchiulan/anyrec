import Foundation
import SlackRecKit

enum Defaults {
    static let outputRoot = "~/Desktop/CallRec Recordings"
}

struct CaptureChoice: Equatable {
    let target: CaptureTarget
    let label: String

    static let auto = CaptureChoice(
        target: .autoDetect, label: "Auto — first call app running"
    )
}

/// Everything the setup screen edits, and the shapes the recorder wants it in.
struct Settings {
    var capture = CaptureChoice.auto
    /// Nil means the microphone is not recorded. The device is always explicit, so
    /// another app switching the system default mid-call cannot redirect the capture.
    var microphone: AudioInputDevice?
    var systemAudio = true
    var stopAfter: TimeInterval?
    var mux = true
    var fps = 30
    var codec: VideoCodec = .h264
    var outputRoot: String

    static let stopChoices: [TimeInterval?] = [nil, 900, 1_800, 2_700, 3_600, 7_200]

    var options: CaptureOptions {
        CaptureOptions(
            fps: fps,
            codec: codec,
            captureSystemAudio: systemAudio,
            captureMicrophone: microphone != nil,
            microphoneDeviceID: microphone?.id,
            showsCursor: true
        )
    }

    var microphoneLabel: String {
        microphone.map { "\($0.name)\($0.isDefault ? " (system default)" : "")" } ?? "Off"
    }

    var stopLabel: String {
        guard let stopAfter else { return "when I press q" }
        let minutes = Int(stopAfter) / 60
        return minutes % 60 == 0 ? "after \(minutes / 60)h" : "after \(minutes)m"
    }

    var muxLabel: String {
        guard mux else { return "Off — separate tracks only" }
        return Muxer.ffmpegPath() == nil ? "On — but ffmpeg is missing" : "On — call.mp4"
    }

    mutating func cycleStop(by delta: Int) {
        let index = Self.stopChoices.firstIndex { $0 == stopAfter } ?? 0
        let next = (index + delta + Self.stopChoices.count) % Self.stopChoices.count
        stopAfter = Self.stopChoices[next]
    }
}
