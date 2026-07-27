import ArgumentParser
import Foundation
import SlackRecKit

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record until Ctrl-C."
    )

    @Option(name: .shortAndLong, help: "Directory the recording folder is created in.")
    var output = Defaults.outputRoot

    @Option(name: .long, help: "Capture a whole display (see `slack-rec sources`).")
    var display: Int?

    @Option(name: .long, help: "Capture one window id (see `slack-rec sources`).")
    var window: UInt32?

    @Option(name: .long, help: "Frames per second (1–60).")
    var fps = 30

    @Option(name: .long, help: "Video codec.")
    var codec: VideoCodec = .h264

    @Option(name: .long, help: "Microphone device id (see `slack-rec sources`).")
    var mic: String?

    @Flag(inversion: .prefixedNo, help: "Record what the call plays back.")
    var systemAudio = true

    @Flag(inversion: .prefixedNo, help: "Record your microphone.")
    var microphone = true

    @Flag(name: .long, help: "Leave the mouse cursor out of the video.")
    var hideCursor = false

    @Flag(inversion: .prefixedNo, help: "Merge the tracks into call.mp4 with ffmpeg afterwards.")
    var mux = true

    func validate() throws {
        switch (window, display) {
        case (nil, nil):
            throw ValidationError(
                "Nothing to record. Pass --window or --display; `slack-rec sources` lists both."
            )
        case (.some, .some):
            throw ValidationError("Pass either --window or --display, not both.")
        default: break
        }
    }

    func run() async throws {
        try await Permissions.preflight(needsMicrophone: microphone)

        let resolved = try await TargetResolver.resolve(target)
        let plan = try OutputPlan.create(in: URL(filePath: output.expandingTilde))
        let recorder = Recorder(options: options, target: resolved, plan: plan)

        try await recorder.start()
        print(startBanner(resolved, plan: plan))
        if let warning = ffmpegWarning() { print(warning) }

        await Interrupt.wait()
        print("\nFinishing…")
        let summary = try await recorder.stop()
        print(Report.render(summary))

        if mux { try muxTracks(plan) }
    }

    /// `validate()` has already ruled out the other combinations.
    private var target: CaptureTarget {
        if let window { return .window(id: window) }
        return .display(index: display ?? 0)
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

    private func startBanner(_ target: ResolvedTarget, plan: OutputPlan) -> String {
        let tracks = [
            "video",
            systemAudio ? "system audio" : nil,
            microphone ? "microphone" : nil,
        ].compactMap { $0 }.joined(separator: " + ")

        return """
        Recording \(target.describing) at \(target.width)×\(target.height), \(fps) fps
        Tracks:    \(tracks)
        Folder:    \(plan.directory.path)
        Stops:     on Ctrl-C
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
        print("Wrote \(merged.output.path)")
        for note in merged.notes { print("\n" + note) }
    }
}

extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
