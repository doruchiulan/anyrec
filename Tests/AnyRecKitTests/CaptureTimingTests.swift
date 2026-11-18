import CoreAudio
import Foundation
import Testing

@testable import AnyRecKit

@Suite("Capture timing facts")
struct CaptureTimingTests {
    private let device = CaptureTiming.Device(
        name: "Desk speakers", uid: "desk-uid", transport: "usb", sampleRate: 48_000, latency: 480,
        safetyOffset: 96, streamLatency: 240, bufferSize: 512)

    @Test("keeps the first eight buffers, the last one, and the count")
    func stream() {
        var stream = CaptureTiming.Stream()
        for index in 0..<20 {
            stream.note(.init(presentation: Double(index), arrival: Double(index) + 0.03, duration: 0.01))
        }
        #expect(stream.first.count == 8 && stream.count == 20 && stream.last?.presentation == 19)
        #expect(abs((stream.age ?? 0) - 0.03) < 1e-9)
    }

    @Test("the stamping gap is the microphone's age minus the system audio's")
    func gap() {
        var timing = CaptureTiming()
        timing.streams[CaptureTiming.microphoneStream] = .init(first: [.init(presentation: 10, arrival: 10.6, duration: 0.01)])
        timing.streams[CaptureTiming.systemAudio] = .init(first: [.init(presentation: 10.5, arrival: 10.6, duration: 0.01)])
        #expect(abs((timing.stampingGap ?? 0) - 0.5) < 1e-9)
        #expect(CaptureTiming().stampingGap == nil)
    }

    @Test("a device's reported latency, in seconds")
    func latency() {
        #expect(abs(device.totalLatency - 1_328.0 / 48_000) < 1e-12)
        #expect(AudioDeviceFacts.transport(kAudioDeviceTransportTypeBluetooth) == "bluetooth")
        #expect(AudioDeviceFacts.transport(kAudioDeviceTransportTypeDisplayPort) == "displayport")
    }

    @Test("round-trips through recording.json, and older files read without it")
    func recordingJSON() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-timing-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var timing = CaptureTiming(sessionStart: 1_000.25, output: device, input: device)
        timing.streams[CaptureTiming.systemAudio] = .init(first: [.init(presentation: 1_000.5, arrival: 1_000.52, duration: 0.02)], count: 1)
        let info = RecordingInfo(title: "Design review", bundleID: "com.tinyspeck.slackmacgap", width: 10, height: 10,
                                 fps: 30, timing: timing)
        try info.write(to: directory)
        #expect(RecordingInfo.read(directory) == info)

        let old = #"{"title":"Design review","bundleID":"com.tinyspeck.slackmacgap","width":10,"height":10,"fps":30}"#
        try Data(old.utf8).write(to: RecordingLayout(directory: directory).writeURL(RecordingInfo.fileName))
        let read = try #require(RecordingInfo.read(directory))
        #expect(read.timing == nil && read.title == "Design review")

        let broken = #"{"title":"Design review","width":10,"height":10,"fps":30,"timing":{"streams":7}}"#
        try Data(broken.utf8).write(to: RecordingLayout(directory: directory).writeURL(RecordingInfo.fileName))
        #expect(RecordingInfo.read(directory)?.timing == nil)
        #expect(RecordingInfo.read(directory)?.title == "Design review")
    }
}
