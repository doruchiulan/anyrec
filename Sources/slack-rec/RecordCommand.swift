import ArgumentParser
import Foundation
import SlackRecKit

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record until Ctrl-C, or until --for elapses."
    )

    @Option(name: .shortAndLong, help: "Directory the recording folder is created in.")
    var output = "~/Desktop/CallRec Recordings"

    @Option(name: .long, help: "Capture a whole display instead of Slack's windows.")
    var display: Int?

    @Option(name: .long, help: "Capture one window id (see `slack-rec windows`).")
    var window: UInt32?

    @Option(name: .long, help: "Bundle id of the app to capture.")
    var bundleId = CaptureTarget.slackBundleID

    @Option(name: .long, help: "Frames per second (1–60).")
    var fps = 30

    @Option(name: .long, help: "Video codec.")
    var codec: VideoCodec = .h264

    @Option(name: .long, help: "Microphone device id (see `slack-rec mics`).")
    var mic: String?

    @Option(name: .customLong("for"), help: "Stop automatically after e.g. 45m, 90s, 1h30m.")
    var duration: String?

    @Flag(inversion: .prefixedNo, help: "Record what the call plays back.")
    var systemAudio = true

    @Flag(inversion: .prefixedNo, help: "Record your microphone.")
    var microphone = true

    @Flag(name: .long, help: "Leave the mouse cursor out of the video.")
    var hideCursor = false

    @Flag(inversion: .prefixedNo, help: "Merge the tracks into call.mp4 with ffmpeg afterwards.")
    var mux = true

    func run() async throws {
        let seconds = try duration.map(DurationSpec.parse)
        try await Permissions.preflight(needsMicrophone: microphone)

        let resolved = try await TargetResolver.resolve(target)
        let plan = try OutputPlan.create(in: URL(filePath: output.expandingTilde))
        let recorder = Recorder(options: options, target: resolved, plan: plan)

        try await recorder.start()
        print(startBanner(resolved, plan: plan, seconds: seconds))
        if let warning = ffmpegWarning() { print(warning) }

        await Interrupt.wait(timeout: seconds)
        print("\nFinishing…")
        let summary = try await recorder.stop()
        print(Report.render(summary))

        if mux { try muxTracks(plan) }
    }

    private var target: CaptureTarget {
        if let window { return .window(id: window) }
        if let display { return .display(index: display) }
        return .application(bundleID: bundleId)
    }

    private var options: CaptureOptions {
        CaptureOptions(
            fps: fps,
            codec: codec,
            captureSystemAudio: systemAudio,
            captureMicrophone: microphone,
            microphoneDeviceID: mic,
            showsCursor: !hideCursor
        )
    }

    private func startBanner(
        _ target: ResolvedTarget, plan: OutputPlan, seconds: TimeInterval?
    ) -> String {
        let tracks = [
            "video",
            systemAudio ? "system audio" : nil,
            microphone ? "microphone" : nil,
        ].compactMap { $0 }.joined(separator: " + ")
        let stopsAt = seconds.map { "after \(Int($0))s" } ?? "on Ctrl-C"

        return """
        Recording \(target.describing) at \(target.width)×\(target.height), \(fps) fps
        Tracks:    \(tracks)
        Folder:    \(plan.directory.path)
        Stops:     \(stopsAt)
        Then:      \(mux ? "merges into call.mp4 (--no-mux to skip)" : "leaves the tracks separate")

        Everyone on this call should know it is being recorded.
        """
    }

    private func ffmpegWarning() -> String? {
        guard mux, Muxer.ffmpegPath() == nil else { return nil }
        return """

        Warning: ffmpeg is not on PATH, so there will be no combined call.mp4 —
        only the separate tracks, and screen.mov carries no audio. Stop now and
        run `brew install ffmpeg` if you want one playable file.
        """
    }

    private func muxTracks(_ plan: OutputPlan) throws {
        guard Muxer.ffmpegPath() != nil else {
            print(
                """
                No call.mp4: ffmpeg is not on PATH. The separate tracks are intact —
                install ffmpeg (brew install ffmpeg) and merge them with:
                  ffmpeg -i screen.mov -i system-audio.m4a -i microphone.m4a \\
                    -filter_complex "[1:a][2:a]amix=inputs=2:duration=longest:normalize=0[a]" \\
                    -map 0:v -map "[a]" -c:v copy -c:a aac call.mp4
                """
            )
            return
        }
        print("Muxing with ffmpeg…")
        let merged = try Muxer.mux(plan)
        print("Wrote \(merged.path)")
    }
}

extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
