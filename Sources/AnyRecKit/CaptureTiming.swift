import CoreAudio
import CoreMedia
import Foundation

/// What capture knew about time, kept in `recording.json` so the offset between the two
/// audio tracks can be traced to its cause after the fact.
///
/// ScreenCaptureKit stamps each output's buffers itself, and the system-audio and
/// microphone stamps were found half a second apart on one call and 60 ms on another. What
/// sets the gap is not documented, so the evidence is kept: for each output, its first
/// buffers' presentation time against the host clock at the moment they reached the
/// recorder; and the default devices' latencies as Core Audio reports them. Set beside the
/// offset measured from the echo, these say whether the gap follows from the devices.
public struct CaptureTiming: Codable, Equatable, Sendable {
    public struct Buffer: Codable, Equatable, Sendable {
        /// The buffer's presentation time, seconds on the host clock.
        public let presentation: Double
        /// The host clock when the recorder was handed it.
        public let arrival: Double
        /// Seconds of media it holds.
        public let duration: Double

        public init(presentation: Double, arrival: Double, duration: Double) {
            self.presentation = presentation
            self.arrival = arrival
            self.duration = duration
        }

        /// How long before arrival its first sample is stamped.
        public var age: Double { arrival - presentation }
    }

    public struct Stream: Codable, Equatable, Sendable {
        public var first: [Buffer] = []
        public var last: Buffer?
        public var count = 0

        public init(first: [Buffer] = [], last: Buffer? = nil, count: Int = 0) {
            self.first = first
            self.last = last
            self.count = count
        }

        static let kept = 8

        mutating func note(_ buffer: Buffer) {
            if first.count < Self.kept { first.append(buffer) }
            last = buffer
            count += 1
        }

        /// The median age of the buffers kept: how far behind its arrival this output
        /// stamps its sound.
        public var age: Double? {
            let ages = (first + (last.map { [$0] } ?? [])).map(\.age).sorted()
            return ages.isEmpty ? nil : ages[ages.count / 2]
        }
    }

    /// One audio device as Core Audio describes it, in the scope it was used in.
    public struct Device: Codable, Equatable, Sendable {
        public let name: String
        public let uid: String
        /// "built-in", "bluetooth", "bluetooth-le", "usb", "hdmi", "displayport", "airplay",
        /// "aggregate", "virtual", "thunderbolt", "pci", "firewire", or the four-character code.
        public let transport: String
        public let sampleRate: Double
        /// Frames, as reported: `kAudioDevicePropertyLatency`, the safety offset, the first
        /// stream's `kAudioStreamPropertyLatency`, and the IO buffer size.
        public let latency: UInt32
        public let safetyOffset: UInt32
        public let streamLatency: UInt32
        public let bufferSize: UInt32

        public init(name: String, uid: String, transport: String, sampleRate: Double, latency: UInt32,
                    safetyOffset: UInt32, streamLatency: UInt32, bufferSize: UInt32) {
            self.name = name
            self.uid = uid
            self.transport = transport
            self.sampleRate = sampleRate
            self.latency = latency
            self.safetyOffset = safetyOffset
            self.streamLatency = streamLatency
            self.bufferSize = bufferSize
        }

        /// Everything the device says sits between the sound and the clock, in seconds.
        public var totalLatency: Double {
            guard sampleRate > 0 else { return 0 }
            return (Double(latency) + Double(safetyOffset) + Double(streamLatency) + Double(bufferSize)) / sampleRate
        }
    }

    /// Keyed "screen", "audio", "microphone" and "microphone-clean".
    public var streams: [String: Stream]
    /// The presentation time every writer's session starts at, seconds on the host clock.
    public var sessionStart: Double?
    /// The default output and input when capture started, and the microphone recorded
    /// when that was another device.
    public var output: Device?
    public var input: Device?
    public var microphone: Device?
    /// Why there is no echo-cancelled microphone track, when one was asked for.
    public var cleanMicrophoneProblem: String?

    public init(streams: [String: Stream] = [:], sessionStart: Double? = nil, output: Device? = nil,
                input: Device? = nil, microphone: Device? = nil, cleanMicrophoneProblem: String? = nil) {
        self.streams = streams
        self.sessionStart = sessionStart
        self.output = output
        self.input = input
        self.microphone = microphone
        self.cleanMicrophoneProblem = cleanMicrophoneProblem
    }

    public static let screen = "screen", systemAudio = "audio", microphoneStream = "microphone",
        cleanMicrophone = "microphone-clean"

    /// How much later the system track's sound is stamped than the microphone's, from
    /// what arrived together: the microphone's age minus the system audio's. If the
    /// offset measured from the echo equals this, the two outputs simply stamp at
    /// different points in the pipeline.
    public var stampingGap: Double? {
        guard let mic = streams[Self.microphoneStream]?.age, let system = streams[Self.systemAudio]?.age
        else { return nil }
        return mic - system
    }

    static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}

/// Reads the default devices from Core Audio. Needs no permission.
public enum AudioDeviceFacts {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    public static func defaultOutput() -> CaptureTiming.Device? {
        device(selector: kAudioHardwarePropertyDefaultOutputDevice).flatMap { describe($0, scope: kAudioObjectPropertyScopeOutput) }
    }

    public static func defaultInput() -> CaptureTiming.Device? {
        device(selector: kAudioHardwarePropertyDefaultInputDevice).flatMap { describe($0, scope: kAudioObjectPropertyScopeInput) }
    }

    /// The input device with this unique id — what `AVCaptureDevice.uniqueID` and the
    /// microphone setting carry.
    public static func input(uid: String) -> CaptureTiming.Device? {
        deviceID(uid: uid).flatMap { describe($0, scope: kAudioObjectPropertyScopeInput) }
    }

    public static func deviceID(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
        }
        return status == noErr && id != 0 ? id : nil
    }

    public static func defaultInputID() -> AudioDeviceID? { device(selector: kAudioHardwarePropertyDefaultInputDevice) }

    private static func device(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func describe(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> CaptureTiming.Device {
        let streams: [AudioStreamID] = array(id, kAudioDevicePropertyStreams, scope: scope)
        return CaptureTiming.Device(
            name: string(id, kAudioObjectPropertyName) ?? "",
            uid: string(id, kAudioDevicePropertyDeviceUID) ?? "",
            transport: transport(number(id, kAudioDevicePropertyTransportType) ?? 0),
            sampleRate: double(id, kAudioDevicePropertyNominalSampleRate) ?? 0,
            latency: number(id, kAudioDevicePropertyLatency, scope: scope) ?? 0,
            safetyOffset: number(id, kAudioDevicePropertySafetyOffset, scope: scope) ?? 0,
            streamLatency: streams.first.flatMap { number($0, kAudioStreamPropertyLatency) } ?? 0,
            bufferSize: number(id, kAudioDevicePropertyBufferFrameSize, scope: scope) ?? 0)
    }

    static func transport(_ code: UInt32) -> String {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: "built-in"
        case kAudioDeviceTransportTypeBluetooth: "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: "bluetooth-le"
        case kAudioDeviceTransportTypeUSB: "usb"
        case kAudioDeviceTransportTypeHDMI: "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: "displayport"
        case kAudioDeviceTransportTypeAirPlay: "airplay"
        case kAudioDeviceTransportTypeAggregate: "aggregate"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        case kAudioDeviceTransportTypeThunderbolt: "thunderbolt"
        case kAudioDeviceTransportTypePCI: "pci"
        case kAudioDeviceTransportTypeFireWire: "firewire"
        case 0: "unknown"
        default:
            String(bytes: withUnsafeBytes(of: code.bigEndian, Array.init), encoding: .ascii) ?? "\(code)"
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope)
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func double(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var address = address(selector, kAudioObjectPropertyScopeGlobal)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector, kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func array(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}
