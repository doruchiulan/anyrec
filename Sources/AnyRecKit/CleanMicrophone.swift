import AVFoundation
import CoreAudio
import Foundation

/// The microphone a second time, through macOS voice processing, so the far end's voice
/// coming back out of the speakers is cancelled at capture instead of held down afterwards.
///
/// The same idea as a browser's `echoCancellation`: the microphone is opened through the
/// voice-processing I/O unit, which subtracts what the Mac is playing, while the system
/// audio is still captured untouched by ScreenCaptureKit. The raw ScreenCaptureKit
/// microphone stays the master; this is written beside it as `microphone-clean.m4a` and
/// nothing depends on it being there.
///
/// Voice processing turns other audio down while it runs. That is set to its minimum, with
/// the advanced mode off, so the call is not made quieter for the person on it.
///
/// Time: the input tap's `AVAudioTime` carries a host time, the same mach clock
/// ScreenCaptureKit stamps its buffers on, so each buffer is stamped with that host time
/// and written against the recorder's one session start. Voice processing adds latency of
/// its own that the host time may not account for, so the clean track is lined up against
/// the raw one afterwards from the owner's voice, which both carry
/// (`MixDecision.cleanMicrophoneOffset`), rather than trusted to the stamp.
final class CleanMicrophone {
    enum Problem: Error, LocalizedError, CustomStringConvertible {
        case notAuthorized
        case deviceNotFound(String)
        case deviceNotSelectable(OSStatus)
        case voiceProcessing(Error)
        case noInput
        case start(Error)

        var description: String {
            switch self {
            case .notAuthorized: "microphone access has not been granted"
            case .deviceNotFound(let uid): "the microphone \(uid) is not connected"
            case .deviceNotSelectable(let status): "voice processing could not be pointed at the microphone (\(status))"
            case .voiceProcessing(let error): "voice processing could not be turned on: \(error.localizedDescription)"
            case .noInput: "voice processing offered no input"
            case .start(let error): "the audio engine did not start: \(error.localizedDescription)"
            }
        }

        var errorDescription: String? { description }
    }

    private let engine = AVAudioEngine()
    private let fold = AVAudioMixerNode()
    let deviceUID: String?
    private let deliver: (CMSampleBuffer, Double) -> Void
    private let interrupted: () -> Void
    private var running = false
    private var observer: NSObjectProtocol?

    /// `deliver` is called on the audio thread with each buffer, stamped on the host
    /// clock, and the host clock when it arrived. It must hand the buffer off at once.
    ///
    /// `interrupted` is called when the engine stops itself: `AVAudioEngine` stops on any
    /// change to its devices' configuration — the default input or output moving, the
    /// device going, its format changing — and never starts again on its own. The owner
    /// starts a new one on whichever device the microphone is on by then
    /// (`MicrophoneRoute`), continuing the same file.
    init(deviceUID: String?, deliver: @escaping (CMSampleBuffer, Double) -> Void,
         interrupted: @escaping () -> Void = {}) {
        self.deviceUID = deviceUID
        self.deliver = deliver
        self.interrupted = interrupted
    }

    deinit { stop() }

    /// Whether the engine is still running. False once a configuration change stopped it.
    var isRunning: Bool { running && engine.isRunning }

    func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw Problem.notAuthorized }
        let input = engine.inputNode
        do { try input.setVoiceProcessingEnabled(true) } catch { throw Problem.voiceProcessing(error) }
        if let deviceUID, let unit = input.audioUnit {
            guard var device = AudioDeviceFacts.deviceID(uid: deviceUID) else { throw Problem.deviceNotFound(deviceUID) }
            if device != AudioDeviceFacts.defaultInputID() {
                let status = AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                    UInt32(MemoryLayout<AudioDeviceID>.size))
                guard status == noErr else { throw Problem.deviceNotSelectable(status) }
            }
        }
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Problem.noInput }
        /// Voice processing can present several channels; one is what is kept. A mixer
        /// folds them, and its silence is what reaches the speakers.
        let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
        engine.attach(fold)
        engine.connect(input, to: fold, format: format)
        engine.connect(fold, to: engine.mainMixerNode, format: mono)
        fold.outputVolume = 0
        let deliver = deliver
        fold.installTap(onBus: 0, bufferSize: 1_024, format: mono) { buffer, time in
            let arrival = CaptureTiming.now()
            guard time.isHostTimeValid, let sample = Self.sampleBuffer(buffer, hostTime: time.hostTime) else { return }
            deliver(sample, arrival)
        }
        engine.prepare()
        let interrupted = interrupted
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in interrupted() }
        do { try engine.start() } catch {
            fold.removeTap(onBus: 0)
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            throw Problem.start(error)
        }
        running = true
    }

    func stop() {
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        guard running else { return }
        fold.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        running = false
    }

    /// A copy of `buffer` as a sample buffer presented at `hostTime`. The data is copied,
    /// so the engine may reuse its buffer as soon as this returns.
    static func sampleBuffer(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) -> CMSampleBuffer? {
        AudioBuffers.sample(buffer, at: CMClockMakeHostTimeFromSystemUnits(hostTime))
    }

    /// Whether a recorded clean track can stand in for the raw one: it carries sound, it
    /// runs most of the raw track's length, and it is not far quieter than the raw track.
    /// Voice processing changes the owner's level by a few decibels; thirty means it
    /// failed and wrote near silence. Anything else and the raw track is used.
    static func usable(_ clean: AudioEnvelope?, besideRaw raw: AudioEnvelope?) -> Bool {
        guard let clean, !clean.isEmpty else { return false }
        let loud = level(clean, percentile: 0.95)
        guard loud > minimumLevel else { return false }
        guard let raw, !raw.isEmpty else { return true }
        guard clean.duration >= raw.duration * coverage else { return false }
        return loud >= level(raw, percentile: 0.95) * quietest
    }

    /// Sample units, about −70 dBFS.
    static let minimumLevel = 10.0
    static let coverage = 0.9
    /// −30 dB.
    static let quietest = 0.0316

    private static func level(_ envelope: AudioEnvelope, percentile: Double) -> Double {
        let sorted = envelope.frames.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * percentile))]
    }
}
