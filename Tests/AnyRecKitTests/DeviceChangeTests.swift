import Foundation
import ScreenCaptureKit
import Testing

@testable import AnyRecKit

@Suite("Microphone route across device changes")
struct MicrophoneRouteTests {
    private let mac = "BuiltInMicrophoneDevice", airpods = "AirPods-input", usb = "USB-mic"
    private let speakers = "BuiltInSpeakerDevice", airpodsOut = "AirPods-output"

    private func facts(default input: String?, _ inputs: [String], output: String? = "BuiltInSpeakerDevice",
                       cleanRunning: Bool = true) -> MicrophoneRoute.Facts {
        .init(defaultInput: input, inputs: inputs, defaultOutput: output, cleanRunning: cleanRunning)
    }

    @Test("a microphone nobody picked follows the default input to AirPods and back")
    func followsDefault() {
        var route = MicrophoneRoute(choice: .followsDefault, facts: facts(default: mac, [mac]), recordsClean: true)
        #expect(route.raw == mac && route.clean == mac)

        let toAirPods = route.update(facts(default: airpods, [mac, airpods], output: airpodsOut))
        #expect(toAirPods?.reason == .defaultChanged)
        #expect(toAirPods?.input == .init(from: mac, to: airpods))
        #expect(toAirPods?.output == .init(from: speakers, to: airpodsOut))
        #expect(toAirPods?.switchRaw == true && toAirPods?.restartClean == true && toAirPods?.clean == airpods)
        #expect(toAirPods?.affected == [CaptureTiming.microphoneStream, CaptureTiming.cleanMicrophone])
        #expect(route.raw == airpods && route.clean == airpods)

        let back = route.update(facts(default: mac, [mac, airpods]))
        #expect(back?.reason == .defaultChanged && back?.input?.to == mac && route.raw == mac)
        #expect(route.update(facts(default: mac, [mac, airpods])) == nil, "nothing moved, nothing to do")
    }

    @Test("a picked microphone stays on its device while the default moves")
    func pickedStays() {
        var route = MicrophoneRoute(choice: .pinned(usb), facts: facts(default: mac, [mac, usb]), recordsClean: true)
        #expect(route.raw == usb)
        #expect(route.update(facts(default: airpods, [mac, usb, airpods])) == nil)
        #expect(route.raw == usb && route.clean == usb)
        let output = route.update(facts(default: airpods, [mac, usb, airpods], output: airpodsOut))
        #expect(output?.reason == .outputChanged && output?.switchRaw == false && output?.restartClean == false)
    }

    @Test("a picked microphone that disappears moves to the default, and back when it returns")
    func pickedVanishes() {
        var route = MicrophoneRoute(choice: .pinned(usb), facts: facts(default: mac, [mac, usb]), recordsClean: true)
        let gone = route.update(facts(default: mac, [mac]))
        #expect(gone?.reason == .deviceGone && gone?.input == .init(from: usb, to: mac) && gone?.switchRaw == true)
        #expect(route.raw == mac && route.clean == mac)

        let back = route.update(facts(default: mac, [mac, usb]))
        #expect(back?.reason == .deviceBack && back?.input?.to == usb && route.raw == usb)
    }

    @Test("a followed microphone that disappears moves to whatever input is left")
    func followedVanishes() {
        var route = MicrophoneRoute(choice: .followsDefault, facts: facts(default: airpods, [mac, airpods]))
        /// The default has not caught up yet: it still names the device that went.
        let gone = route.update(facts(default: airpods, [mac, usb]))
        #expect(gone?.reason == .deviceGone && gone?.input?.to == mac, "the first input left")
        let none = route.update(facts(default: nil, []))
        #expect(none?.input == .init(from: mac, to: nil) && none?.switchRaw == false, "nothing to point the stream at")
    }

    @Test("an unreadable device list leaves a picked microphone where it is")
    func unreadableList() {
        #expect(MicrophoneRoute.target(for: .pinned(usb), facts: facts(default: mac, []), current: usb) == usb)
    }

    @Test("the clean microphone is started again when its engine stops, on the raw microphone's device")
    func cleanRestart() {
        var route = MicrophoneRoute(choice: .followsDefault, facts: facts(default: mac, [mac]), recordsClean: true)
        let output = route.update(facts(default: mac, [mac], output: airpodsOut, cleanRunning: false))
        #expect(output?.reason == .outputChanged && output?.switchRaw == false)
        #expect(output?.restartClean == true && output?.clean == mac && output?.affected == [CaptureTiming.cleanMicrophone])

        let interrupted = route.update(facts(default: mac, [mac], output: airpodsOut, cleanRunning: false))
        #expect(interrupted?.reason == .cleanInterrupted && interrupted?.restartClean == true)

        route.cleanFailed()
        #expect(route.update(facts(default: mac, [mac], output: airpodsOut, cleanRunning: false))?.restartClean == true,
                "a failed start is tried again on the next change")
        route.dropClean()
        #expect(route.update(facts(default: mac, [mac], output: airpodsOut, cleanRunning: false)) == nil,
                "a clean track that could not be written is not started again")
    }

    @Test("without echo cancellation only the raw microphone moves")
    func rawOnly() {
        var route = MicrophoneRoute(choice: .followsDefault, facts: facts(default: mac, [mac]))
        let change = route.update(facts(default: airpods, [mac, airpods], cleanRunning: false))
        #expect(change?.switchRaw == true && change?.restartClean == false && change?.affected == [CaptureTiming.microphoneStream])
    }
}

@Suite("Recorder across device changes")
struct RecorderDeviceChangeTests {
    private func error(_ code: SCStreamError.Code) -> NSError {
        NSError(domain: SCStreamError.errorDomain, code: code.rawValue)
    }

    @Test("a stream stopped by the microphone vanishing is a device change, not a failure")
    func vanishedDevice() {
        #expect(Recorder.stoppedByDeviceChange(error(.internalError), microphoneGone: true, changedRecently: false))
        #expect(Recorder.stoppedByDeviceChange(error(.systemStoppedStream), microphoneGone: false, changedRecently: true))
        #expect(Recorder.stoppedByDeviceChange(error(.failedToStartMicrophoneCapture), microphoneGone: false, changedRecently: false))
        #expect(Recorder.stoppedByDeviceChange(NSError(domain: NSOSStatusErrorDomain, code: -50), microphoneGone: true, changedRecently: false))
    }

    @Test("a stop with no device change behind it is still a failure, and a closed window still the end")
    func otherStops() {
        #expect(!Recorder.stoppedByDeviceChange(error(.internalError), microphoneGone: false, changedRecently: false))
        #expect(!Recorder.stoppedByDeviceChange(error(.noCaptureSource), microphoneGone: true, changedRecently: true))
        #expect(!Recorder.stoppedByDeviceChange(error(.userStopped), microphoneGone: true, changedRecently: true))
    }

    @Test("a stream that cannot be started again ends the recording rather than failing it")
    func cannotRestart() {
        let ended = RecorderError.deviceChangeEnded(NSError(domain: "anyrec", code: 1))
        #expect(Recorder.endOfRecording(ended)?.contains("audio device changed") == true)
    }

    @Test("the buffers still at the old device's rate after a switch mean it did not move")
    func unmoved() {
        #expect(Recorder.unmoved(before: 48_000, after: 48_000, expected: 24_000))
        #expect(!Recorder.unmoved(before: 48_000, after: 24_000, expected: 24_000))
        #expect(!Recorder.unmoved(before: 48_000, after: 48_000, expected: 48_000), "same rate says nothing")
        #expect(!Recorder.unmoved(before: nil, after: 48_000, expected: 24_000))
    }

    @Test("a microphone nobody picked follows the default; one picked by hand does not")
    func configurationChoice() {
        var configuration = RecordingConfiguration()
        configuration.pinDefaultMicrophone(from: [AudioInputDevice(id: "mac", name: "MacBook Pro Microphone", isDefault: true)])
        #expect(configuration.followsDefaultMicrophone && configuration.options.followsDefaultMicrophone)
        #expect(configuration.options.microphoneDeviceID == "mac")

        var picked = RecordingConfiguration()
        picked.microphone = AudioInputDevice(id: "usb", name: "USB", isDefault: false)
        picked.pinDefaultMicrophone(from: [AudioInputDevice(id: "mac", name: "MacBook Pro Microphone", isDefault: true)])
        #expect(!picked.followsDefaultMicrophone && picked.options.microphoneDeviceID == "usb")

        var none = RecordingConfiguration()
        none.pinDefaultMicrophone(from: [])
        #expect(!none.followsDefaultMicrophone && none.microphone == nil)
    }
}

@Suite("Device change facts")
struct DeviceChangeFactsTests {
    private let mac = CaptureTiming.Device(
        name: "MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice", transport: "built-in", sampleRate: 48_000,
        latency: 0, safetyOffset: 0, streamLatency: 2_960, bufferSize: 512)
    private let airpods = CaptureTiming.Device(
        name: "AirPods Pro", uid: "AirPods-input", transport: "bluetooth", sampleRate: 24_000,
        latency: 0, safetyOffset: 0, streamLatency: 1_200, bufferSize: 480)

    @Test("round-trip through recording.json, and older files read without them")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-changes-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var timing = CaptureTiming(sessionStart: 1_000)
        timing.deviceChanges = [
            .init(at: 312.4, reason: .defaultChanged, from: mac, to: airpods, outputFrom: nil, outputTo: airpods,
                  affected: [CaptureTiming.microphoneStream, CaptureTiming.cleanMicrophone]),
            .init(at: 640, reason: .deviceGone, from: airpods, to: mac, affected: [CaptureTiming.microphoneStream],
                  problem: "microphone: updateConfiguration refused the new device"),
        ]
        timing.streams[CaptureTiming.microphoneStream] = .init(
            count: 10, gaps: [.init(at: 312.5, seconds: 0.42)],
            formats: [.init(at: 0, sampleRate: 48_000, channels: 1), .init(at: 312.9, sampleRate: 24_000, channels: 1)])
        try RecordingInfo(title: "Call", bundleID: nil, width: 2, height: 2, fps: 30, timing: timing).write(to: directory)

        let read = try #require(RecordingInfo.read(directory)?.timing)
        #expect(read == timing)
        #expect(read.changeTimes == [312.4, 640])

        let old = Data(#"{"streams":{"microphone":{"first":[],"count":3}},"sessionStart":5}"#.utf8)
        let older = try JSONDecoder().decode(CaptureTiming.self, from: old)
        #expect(older.deviceChanges == nil && older.changeTimes.isEmpty)
        #expect(older.streams[CaptureTiming.microphoneStream]?.gaps == nil)
        #expect(older.streams[CaptureTiming.microphoneStream]?.formats == nil)
    }

    @Test("a stream's format is noted at its first buffer and at every change, not every buffer")
    func formats() {
        var stream = CaptureTiming.Stream()
        stream.noteFormat(.init(at: 0, sampleRate: 48_000, channels: 1))
        stream.noteFormat(.init(at: 1, sampleRate: 48_000, channels: 1))
        stream.noteFormat(.init(at: 300, sampleRate: 24_000, channels: 1))
        stream.noteFormat(.init(at: 600, sampleRate: 24_000, channels: 2))
        #expect(stream.formats?.map(\.at) == [0, 300, 600])
    }
}
