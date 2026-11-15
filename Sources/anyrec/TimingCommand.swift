import ArgumentParser
import Foundation
import AnyRecKit

/// `anyrec timing`: plays a test signal through the current output while recording, and
/// reports how far apart the call's audio and the microphone were stamped.
struct Timing: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "timing",
        abstract: "Measure the offset between the call-audio and microphone tracks on this Mac's devices.",
        discussion: """
        Plays \(Int(TimingCheck.duration)) seconds of noise bursts through the current output \
        while recording the display's audio and the microphone exactly as a call is recorded, \
        then reads the offset from the bursts in both tracks. Turn the speakers up and keep \
        headphones off: the microphone has to hear them. Needs Screen Recording and Microphone \
        access for the terminal.
        """
    )

    @Option(name: .shortAndLong, help: "Where the check's recording folder is made.")
    var output = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-timing").path

    @Option(name: .long, help: "Microphone device id (see `anyrec sources`). The default input otherwise.")
    var mic: String?

    @Flag(inversion: .prefixedNo, help: "Record the echo-cancelled microphone too.")
    var echoCancellation = true

    func run() async throws {
        guard let ffmpeg = Muxer.ffmpegPath() else { throw ValidationError(MuxError.ffmpegNotFound.description) }
        try await Permissions.preflight(needsMicrophone: true, host: .terminal)
        let signal = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-timing-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: signal) }
        try TimingCheck.signal(into: signal, using: ffmpeg)

        var recording = RecordingConfiguration(outputRoot: output)
        recording.capture = CaptureChoice(target: .display(index: 0))
        recording.video = false
        recording.mux = false
        recording.echoCancellation = echoCancellation
        if let mic {
            guard recording.selectMicrophone(id: mic) else { throw ValidationError("No input device with id \(mic).") }
        } else {
            recording.pinDefaultMicrophone()
        }

        let session = try await RecordingSession.start(recording)
        print("Playing the test signal through the speakers for \(Int(TimingCheck.duration)) s…")
        try await Task.sleep(for: .seconds(1))
        _ = try Shell.run("/usr/bin/afplay", [signal.path])
        try await Task.sleep(for: .seconds(1))
        _ = try await session.finishCapture()

        let result = TimingCheck.measure(session.plan, using: ffmpeg)
        print("Folder         \(session.plan.directory.path)")
        print("Track offset   " + EchoReportText.offset(result.systemAudio, what: "call audio behind the microphone"))
        if let clean = result.cleanMicrophone {
            print("Clean mic      " + EchoReportText.offset(clean, what: "echo-cancelled behind the raw microphone"))
        }
        if let timing = result.timing { EchoReportText.timing(timing).forEach { print($0) } }
    }
}
