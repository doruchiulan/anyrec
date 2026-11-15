import Foundation

/// Which device each microphone track records from while devices come and go mid-call.
///
/// A microphone left to the system follows the default input: switch the call to AirPods
/// and the recording switches with it. One picked in Settings (or with `--microphone`)
/// stays on that device for as long as it is connected. Either way a microphone that
/// disappears never ends the recording: it moves to the default input, or failing that
/// the first input there is, and a picked one moves back when it returns. The raw
/// microphone and the echo-cancelled one always go to the same device, because the clean
/// track is lined up against the raw one from the owner's voice, which both have to hear.
///
/// Pure state, fed what Core Audio says, so every decision is testable without a device.
public struct MicrophoneRoute: Equatable, Sendable {
    public enum Choice: Equatable, Sendable {
        /// The system default, followed as it changes.
        case followsDefault
        /// A device picked by its unique id, kept while it is connected.
        case pinned(String)
    }

    /// What Core Audio says at the moment of asking.
    public struct Facts: Equatable, Sendable {
        public var defaultInput: String?
        /// Every connected input, by unique id.
        public var inputs: [String]
        public var defaultOutput: String?
        /// Whether the echo-cancelled microphone's engine is running.
        public var cleanRunning: Bool

        public init(defaultInput: String?, inputs: [String], defaultOutput: String?, cleanRunning: Bool = true) {
            self.defaultInput = defaultInput
            self.inputs = inputs
            self.defaultOutput = defaultOutput
            self.cleanRunning = cleanRunning
        }
    }

    /// What has to happen for the tracks to be where the route says.
    public struct Change: Equatable, Sendable {
        public var reason: CaptureTiming.DeviceChange.Reason
        /// The input before and after, when it moved.
        public var input: Move?
        /// The output before and after, when it moved.
        public var output: Move?
        /// Point ScreenCaptureKit's microphone at `input.to`.
        public var switchRaw: Bool
        /// Start the echo-cancelled microphone again, on `clean`.
        public var restartClean: Bool
        /// The device the clean microphone is started on.
        public var clean: String?

        public var affected: [String] {
            (switchRaw ? [CaptureTiming.microphoneStream] : []) + (restartClean ? [CaptureTiming.cleanMicrophone] : [])
        }
    }

    public struct Move: Equatable, Sendable {
        public var from: String?
        public var to: String?
    }

    public let choice: Choice
    public let recordsRaw: Bool
    public private(set) var recordsClean: Bool
    /// The device each track is recording now, and the default output.
    public private(set) var raw: String?
    public private(set) var clean: String?
    public private(set) var output: String?

    /// The route as capture starts: the raw microphone on `target(for:)`, and the clean one
    /// on the same device once it has started.
    public init(choice: Choice, facts: Facts, recordsRaw: Bool = true, recordsClean: Bool = false) {
        self.choice = choice
        self.recordsRaw = recordsRaw
        self.recordsClean = recordsClean
        raw = Self.target(for: choice, facts: facts, current: nil)
        clean = recordsClean ? raw : nil
        output = facts.defaultOutput
    }

    /// The device a microphone should record from now. A picked device while it is
    /// connected (or while the list of devices cannot be read); otherwise the default input; otherwise the device it is on, if still
    /// there; otherwise the first input there is. Nil when there is no input at all.
    public static func target(for choice: Choice, facts: Facts, current: String?) -> String? {
        /// An empty list is Core Audio not answering, not every device gone.
        if case .pinned(let device) = choice, facts.inputs.isEmpty || facts.inputs.contains(device) { return device }
        if let fallback = facts.defaultInput, facts.inputs.contains(fallback) || facts.inputs.isEmpty { return fallback }
        if let current, facts.inputs.contains(current) { return current }
        return facts.inputs.first
    }

    /// Brings the route up to date with `facts`, and says what has to change for the tracks
    /// to follow. Nil when nothing does.
    public mutating func update(_ facts: Facts) -> Change? {
        let target = Self.target(for: choice, facts: facts, current: raw)
        let outputMoved = facts.defaultOutput != output
        let inputMoved = target != raw
        let switchRaw = recordsRaw && inputMoved && target != nil
        let restartClean = recordsClean && target != nil && (clean != target || !facts.cleanRunning)
        guard inputMoved || outputMoved || restartClean else { return nil }

        let reason: CaptureTiming.DeviceChange.Reason
        if inputMoved, let raw, !facts.inputs.contains(raw) {
            reason = .deviceGone
        } else if inputMoved, case .pinned(let picked) = choice, target == picked {
            reason = .deviceBack
        } else if inputMoved {
            reason = .defaultChanged
        } else if outputMoved {
            reason = .outputChanged
        } else {
            reason = .cleanInterrupted
        }
        let change = Change(
            reason: reason,
            input: inputMoved ? Move(from: raw, to: target) : nil,
            output: outputMoved ? Move(from: output, to: facts.defaultOutput) : nil,
            switchRaw: switchRaw, restartClean: restartClean, clean: restartClean ? target : nil)
        raw = target
        output = facts.defaultOutput
        if restartClean { clean = target }
        return change
    }

    /// The clean microphone could not be started on its device. The next update tries
    /// again, since a device that just appeared is sometimes not ready for a moment.
    public mutating func cleanFailed() {
        clean = nil
    }

    /// The clean track's file could not be written: nothing is gained by starting it again.
    public mutating func dropClean() {
        recordsClean = false
        clean = nil
    }
}
