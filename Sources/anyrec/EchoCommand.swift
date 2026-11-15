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
        far end is left in the raw microphone, under the hold-down before and after the \
        tracks are lined up, and in the echo-cancelled microphone, and what voice processing \
        did to your own level.
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
        if let clean = report.cleanMicrophoneOffset {
            lines.append("Clean mic      " + offset(clean, what: "echo-cancelled behind the raw microphone"))
        }
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
            ("echo-cancelled", report.clean),
            ("echo-cancelled, held down", report.cleanDucked),
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
            var owner = String(format: "Your voice     %.1f dBFS raw", raw)
            if let clean = report.ownerClean, let change = report.ownerChange {
                owner += String(format: ", %.1f dBFS echo-cancelled (%+.1f dB)", clean, change)
            }
            lines.append(owner + ", where only you talk")
        }
        if let bleeds = report.cleanStillBleeds {
            lines.append(bleeds ? "The echo-cancelled microphone still bleeds, so the mixes hold it down too."
                         : "The echo-cancelled microphone does not bleed, so the mixes use it as it is.")
        }
        lines.append("")
        lines.append(verdict(report.verdict))
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

    static func timing(_ timing: CaptureTiming) -> [String] {
        var lines: [String] = []
        if let gap = timing.stampingGap {
            lines.append(String(format: "Stamping gap   %+.0f ms between the outputs' stamps at arrival", gap * 1000))
        }
        for (label, device) in [("Output", timing.output), ("Input", timing.input), ("Microphone", timing.microphone)] {
            guard let device else { continue }
            lines.append(label.padding(toLength: 15, withPad: " ", startingAt: 0)
                + String(format: "%@ (%@), %.0f ms reported latency", device.name, device.transport, device.totalLatency * 1000))
        }
        if let problem = timing.cleanMicrophoneProblem { lines.append("Clean mic      not recorded: \(problem)") }
        return lines
    }

    static func verdict(_ verdict: EchoReport.Verdict) -> String {
        switch verdict {
        case .noEcho: "No echo to measure: headphones, or the far end never came back through the microphone."
        case .noCleanTrack: "No echo-cancelled track in this recording, so there is nothing to compare."
        case .captureWins: "Verdict: cancelling at capture leaves no more echo than the lined-up hold-down. Use it; build nothing more after the fact."
        case .duckWins: "Verdict: the lined-up hold-down leaves less echo than cancelling at capture."
        }
    }
}
