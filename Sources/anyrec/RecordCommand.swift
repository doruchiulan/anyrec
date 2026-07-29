import ArgumentParser
import Foundation
import AnyRecKit

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record until Ctrl-C."
    )

    @Option(name: .shortAndLong, help: "Directory the recording folder is created in.")
    var output = Defaults.outputRoot

    @Option(name: .long, help: "Capture a whole display (see `anyrec sources`).")
    var display: Int?

    @Option(name: .long, help: "Capture one window id (see `anyrec sources`).")
    var window: UInt32?

    @Option(name: .long, help: "Frames per second (1–60).")
    var fps = 30

    @Option(name: .long, help: "Video codec.")
    var codec: VideoCodec = .h264

    @Option(name: .long, help: "Microphone device id (see `anyrec sources`).")
    var mic: String?

    @Flag(inversion: .prefixedNo, help: "Record what the call plays back.")
    var systemAudio = true

    @Flag(inversion: .prefixedNo, help: "Record your microphone.")
    var microphone = true

    @Flag(name: .long, help: "Leave the mouse cursor out of the video.")
    var hideCursor = false

    @Flag(inversion: .prefixedNo, help: "Merge the tracks into call.mp4 with ffmpeg afterwards.")
    var mux = true

    @Option(name: .long, help: "Transcribe afterwards: auto, apple, whisper or openai.")
    var transcribe: TranscriptionEngine?

    func validate() throws {
        switch (window, display) {
        case (nil, nil):
            throw ValidationError(
                "Nothing to record. Pass --window or --display; `anyrec sources` lists both."
            )
        case (.some, .some):
            throw ValidationError("Pass either --window or --display, not both.")
        default: break
        }
    }

    func run() async throws {
        try await Permissions.preflight(needsMicrophone: microphone, host: .terminal)

        let session = try await RecordingSession.start(try recording())
        print(startBanner(session))
        if let warning = ffmpegWarning() { print(warning) }

        await Interrupt.wait()
        let outcome = try await session.stop { print("\n" + SummaryReport.status($0)) }
        print(SummaryReport.render(outcome))
        await TranscriptReport.follow(session)
    }

    private func recording() throws -> RecordingConfiguration {
        var recording = RecordingConfiguration(outputRoot: output)
        recording.capture = CaptureChoice(target: target)
        recording.systemAudio = systemAudio
        recording.mux = mux
        recording.transcribe = transcribe
        recording.fps = fps
        recording.codec = codec
        recording.showsCursor = !hideCursor

        guard microphone else { return recording }
        if let mic {
            guard recording.selectMicrophone(id: mic) else {
                throw ValidationError("No input device with id \(mic). `anyrec sources` lists them.")
            }
        } else {
            recording.pinDefaultMicrophone()
        }
        return recording
    }

    /// `validate()` has already ruled out the other combinations.
    private var target: CaptureTarget {
        if let window { return .window(id: window) }
        return .display(index: display ?? 0)
    }

    private func startBanner(_ session: RecordingSession) -> String {
        let recording = session.configuration
        let target = session.target
        let tracks = [
            "video",
            recording.systemAudio ? "system audio" : nil,
            recording.microphone.map { "microphone (\($0.name))" },
        ].compactMap { $0 }.joined(separator: " + ")

        return """
        Recording \(target.describing) at \(target.width)×\(target.height), \(fps) fps
        Tracks:    \(tracks)
        Folder:    \(session.plan.directory.path)
        Stops:     on Ctrl-C
        Then:      \(mux ? "merges into call.mp4 (--no-mux to skip)" : "leaves the tracks separate")

        Everyone on this call should know it is being recorded.
        """
    }

    private func ffmpegWarning() -> String? {
        guard mux, !Readiness.ffmpegInstalled else { return nil }
        return """

        Warning: ffmpeg is not on PATH, so there will be no combined call.mp4 —
        only the separate tracks, and screen.mov carries no audio. Stop now and
        run `brew install ffmpeg` if you want one playable file.
        """
    }
}
