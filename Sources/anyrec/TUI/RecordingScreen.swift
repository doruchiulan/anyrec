import Foundation
import AnyRecKit

/// The live screen: elapsed time, frame count, and a meter per audio track.
struct RecordingScreen {
    let session: RecordingSession

    private var started = Date()

    init(session: RecordingSession) {
        self.session = session
    }

    enum Ending {
        case stopped
        case deadline
    }

    mutating func run() async -> Ending {
        started = Date()
        while true {
            let elapsed = Date().timeIntervalSince(started)
            if let limit = session.configuration.stopAfter, elapsed >= limit { return .deadline }

            Terminal.write(render(elapsed: elapsed))
            switch Terminal.readKey() {
            case .character("q"), .escape, .interrupt, .enter: return .stopped
            default: break
            }
            await Task.yield()
        }
    }

    private func render(elapsed: TimeInterval) -> String {
        let width = max(20, min(40, Terminal.size().columns - 40))
        let progress = session.progress()
        let target = session.target

        var lines = [
            "",
            "  " + styled("● REC", .bold, .red) + "  " + clock(elapsed) + remaining(elapsed),
            "",
            "  " + styled(clip(target.describing, to: 60), .bold),
            "  "
                + styled(
                    "\(target.width)×\(target.height) · \(session.configuration.fps) fps · \(progress.screenFrames) frames",
                    .dim),
            "",
        ]

        lines += tracks.map { "  " + meter($0, width: width) }
        lines += [
            "",
            "  "
                + styled(
                    clip(session.plan.directory.path, to: Terminal.size().columns - 4), .dim),
        ]

        if DropRate.worthReporting(progress.droppedSamples, of: progress.screenFrames) {
            lines.append(
                "  " + styled("\(progress.droppedSamples) buffers dropped — try --fps 24", .yellow)
            )
        }
        lines += ["", "  " + styled("q or Ctrl-C to stop", .dim)]

        return Terminal.home + lines.map { $0 + Terminal.clearLine }.joined(separator: "\r\n")
            + "\r\n" + Terminal.clearToEnd
    }

    private var tracks: [AudioTrack] {
        let configuration = session.configuration
        return AudioTrack.allCases.filter {
            $0 == .systemAudio ? configuration.systemAudio : configuration.microphone != nil
        }
    }

    private func meter(_ track: AudioTrack, width: Int) -> String {
        Meter.render(
            track.rawValue,
            level: session.levels.level(for: track),
            sessionPeak: session.levels.sessionPeak(for: track),
            width: width
        )
    }

    private func clock(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
    }

    private func remaining(_ elapsed: TimeInterval) -> String {
        guard let limit = session.configuration.stopAfter else { return "" }
        let left = Int(max(0, limit - elapsed))
        return styled("   \(left / 60)m \(left % 60)s left", .dim)
    }
}
