import ArgumentParser
import Foundation
import AnyRecKit

/// `anyrec echo`: after a call on speakers, whether cancelling echo at capture beat holding
/// the microphone down afterwards, and how far apart the tracks were stamped.
struct Echo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "echo",
        abstract: "Measure the track offset and the echo left in one recording.",
        discussion: """
        Reads the tracks only; nothing in the folder is changed. Shows how late the call's \
        track runs behind the microphone (measured from the far end's echo), how much of the \
        far end is left in the raw microphone and under the hold-down before and after the \
        tracks are lined up, and your own level.
        """
    )

    @Argument(help: "A recording folder. Defaults to the newest recording.")
    var recording: String?

    @Option(name: .shortAndLong, help: "Where recordings are, when no folder is given.")
    var output = Defaults.outputRoot

    func run() async throws {
        guard let ffmpeg = Muxer.ffmpegPath() else { throw ValidationError(MuxError.ffmpegNotFound.description) }
        let folder: URL
        if let recording {
            folder = URL(fileURLWithPath: recording.expandingTilde)
        } else if let newest = Recordings.newest(in: URL(fileURLWithPath: output.expandingTilde)) {
            folder = newest
        } else {
            throw ValidationError("No recording found in \(output).")
        }
        guard Recordings.isDirectory(folder) else { throw ValidationError("\(folder.path) is not a recording folder.") }
        print("Measuring \(folder.lastPathComponent)…")
        let report = try EchoCheck.measure(OutputPlan(directory: folder), using: ffmpeg)
        print(EchoReportText.render(report))
    }
}

enum EchoReportText {
    static func render(_ report: EchoReport) -> String {
        var lines: [String] = []
        lines.append("Track offset   " + offset(report.systemAudioOffset, what: "call audio behind the microphone"))
        lines += stretches(report.systemAudioOffset)
        if let timing = report.timing {
            lines += self.timing(timing)
        }
        lines.append("")
        lines.append("Echo left while the far end talks (lower is better)")
        lines.append("                              median   audible  phrase starts")
        let rows: [(String, EchoReport.Echo?)] = [
            ("raw microphone", report.raw),
            ("held down, as before", report.duckedBefore),
            ("held down, lined up", report.duckedAligned),
        ]
        for (label, echo) in rows {
            guard let echo else { continue }
            lines.append(label.padding(toLength: 28, withPad: " ", startingAt: 0)
                + String(format: "%6.1f dB   %4.0f%%   %4.0f%% of %d", echo.median, echo.audible * 100,
                         echo.onsetLoud * 100, echo.phrases))
        }
        lines.append("  audible: share of moments less than 20 dB under the far end;")
        lines.append("  phrase starts: share of each phrase's first half-second less than 12 dB under it.")
        if let raw = report.ownerRaw {
            lines.append("")
            lines.append(String(format: "Your voice     %.1f dBFS, where only you talk", raw))
        }
        if report.noEcho {
            lines.append("")
            lines.append("No echo to measure: headphones, or the far end never came back through the microphone.")
        }
        return lines.joined(separator: "\n")
    }

    static func offset(_ offset: TrackOffset?, what: String) -> String {
        guard let offset else { return "not measured (a track could not be read)" }
        guard let seconds = offset.seconds else {
            return String(format: "not measurable — no echo to line up on (best correlation %.2f over %d windows)",
                          offset.confidence, offset.windowsTried)
        }
        var text = String(format: "%+.0f ms, %@ (correlation %.2f, %d of %d windows)",
                          seconds * 1000, what, offset.confidence, offset.windowsUsed, offset.windowsTried)
        if let drift = offset.driftPerHour { text += String(format: ", drifting %+.0f ms an hour", drift * 1000) }
        return text
    }

    /// The lag of each stretch between device changes, and whether its drift is followed.
    /// Nothing when the call was one stretch with one lag.
    static func stretches(_ offset: TrackOffset?) -> [String] {
        guard let sections = offset?.sections, sections.count > 1 || sections.first?.driftPerHour != nil
        else { return [] }
        return sections.map { section in
            let span = String(format: "  %@–%@  ", clock(section.start), clock(section.end))
            guard let seconds = section.seconds else {
                return span + String(format: "not measurable (best correlation %.2f), takes its neighbour's", section.confidence)
            }
            var text = span + String(format: "%+.0f ms (%d of %d windows)", seconds * 1000,
                                     section.windowsUsed, section.windowsTried)
            if let drift = section.driftPerHour { text += String(format: ", followed drifting %+.0f ms an hour", drift * 1000) }
            return text
        }
    }

    private static func clock(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    static func timing(_ timing: CaptureTiming) -> [String] {
        var lines: [String] = []
        for change in timing.deviceChanges ?? [] {
            var text = "Device change  " + clock(change.at) + "  " + change.reason.rawValue
            if change.from != nil || change.to != nil {
                text += ": " + (change.from.map { "\($0.name) (\($0.transport))" } ?? "none")
                    + " → " + (change.to.map { "\($0.name) (\($0.transport), \(Int(($0.totalLatency * 1000).rounded())) ms)" } ?? "none")
            }
            if let output = change.outputTo { text += "; output → \(output.name)" }
            if !change.affected.isEmpty { text += "; moved " + change.affected.joined(separator: ", ") }
            if let problem = change.problem { text += "; " + problem }
            lines.append(text)
        }
        for (name, stream) in timing.streams.sorted(by: { $0.key < $1.key }) {
            for gap in stream.gaps ?? [] {
                lines.append(String(format: "Gap            %@ in %@: %.0f ms written as silence", clock(gap.at), name, gap.seconds * 1000))
            }
        }
        if let gap = timing.stampingGap {
            lines.append(String(format: "Stamping gap   %+.0f ms between the outputs' stamps at arrival", gap * 1000))
        }
        for (label, device) in [("Output", timing.output), ("Input", timing.input), ("Microphone", timing.microphone)] {
            guard let device else { continue }
            lines.append(label.padding(toLength: 15, withPad: " ", startingAt: 0)
                + String(format: "%@ (%@), %.0f ms reported latency", device.name, device.transport, device.totalLatency * 1000))
        }
        return lines
    }
}
