import Foundation
import AnyRecKit

/// The recording summary and what became of the merge, as one block of text.
enum SummaryReport {
    static func render(_ outcome: RecordingOutcome) -> String {
        Report.render(outcome.summary) + "\n\n" + merge(outcome.merge)
    }

    static func status(_ stage: RecordingSession.Stage) -> String {
        switch stage {
        case .finishing: "Finishing…"
        case .merging: "Merging with ffmpeg…"
        }
    }

    private static func merge(_ outcome: MergeOutcome) -> String {
        switch outcome {
        case .merged(let mux):
            (["  Play this one:  \(mux.output.path)"] + mux.notes.map { "  " + $0 })
                .joined(separator: "\n\n")
        case .notRequested:
            "  The tracks were left separate, as asked."
        case .ffmpegMissing:
            """
              No call.mp4: ffmpeg is not on PATH, so screen.mov carries no audio. The
              separate tracks are intact — install ffmpeg (brew install ffmpeg) and
              merge them with:
                ffmpeg -i screen.mov -i system-audio.m4a -i microphone.m4a \\
                  -filter_complex "[1:a][2:a]amix=inputs=2:duration=longest:normalize=0[a]" \\
                  -map 0:v -map "[a]" -c:v copy -c:a aac call.mp4
            """
        case .failed(let reason):
            "  The three tracks are intact, but the merge failed: \(reason)"
        }
    }
}

enum Report {
    static func render(_ summary: RecordingSummary) -> String {
        var lines = ["", summary.plan.directory.path]
        lines.append(row(summary.plan.screen, count: summary.screenFrames, unit: "frames"))
        lines += AudioTrack.allCases.map { audioRow($0, in: summary) }

        for note in notes(summary) { lines += ["", note] }
        return lines.joined(separator: "\n")
    }

    private static func audioRow(_ track: AudioTrack, in summary: RecordingSummary) -> String {
        let url = track == .systemAudio ? summary.plan.systemAudio : summary.plan.microphone
        let base = row(url, count: summary.samples(for: track), unit: "buffers")
        guard summary.samples(for: track) > 0 else { return base }
        return "\(base), peak \(MeterScale.reading(summary.peak(for: track))) dB"
    }

    private static func notes(_ summary: RecordingSummary) -> [String] {
        var notes = summary.endedEarly.map { [$0] } ?? []
        notes += AudioTrack.allCases.compactMap { track -> String? in
            guard summary.samples(for: track) > 0 else { return nil }
            return MeterScale.verdict(peak: summary.peak(for: track), for: track)
                .map { "\(track.rawValue): \($0)" }
        }
        let captured =
            summary.screenFrames + AudioTrack.allCases.reduce(0) { $0 + summary.samples(for: $1) }
        if DropRate.worthReporting(summary.droppedSamples, of: captured) {
            notes.append(
                "\(summary.droppedSamples) buffers dropped — the encoder could not keep up. "
                    + "Try --fps 24 or --codec hevc."
            )
        }
        return notes
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
