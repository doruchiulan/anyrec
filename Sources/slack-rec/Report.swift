import Foundation
import SlackRecKit

enum Report {
    static func render(_ summary: RecordingSummary) -> String {
        let rows = [
            row(summary.plan.screen, count: summary.screenFrames, unit: "frames"),
            row(summary.plan.systemAudio, count: summary.systemAudioSamples, unit: "buffers"),
            row(summary.plan.microphone, count: summary.microphoneSamples, unit: "buffers"),
        ]
        var lines = ["", summary.plan.directory.path] + rows
        if summary.droppedSamples > 0 {
            lines.append("")
            lines.append(
                "\(summary.droppedSamples) buffers dropped — the encoder could not keep up. "
                    + "Try --fps 24 or --codec hevc."
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func row(_ url: URL, count: Int, unit: String) -> String {
        let name = url.lastPathComponent.padding(toLength: 20, withPad: " ", startingAt: 0)
        guard count > 0 else { return "  \(name)not captured" }
        return "  \(name)\(count) \(unit)\(size(of: url))"
    }

    private static func size(of url: URL) -> String {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let bytes = attributes[.size] as? Int64
        else { return "" }
        return ", \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
}
