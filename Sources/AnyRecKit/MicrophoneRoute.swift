import Foundation

/// Which device the microphone records from while devices come and go mid-call.
///
/// A microphone left to the system follows the default input: switch the call to AirPods
/// and the recording switches with it. One picked in Settings (or with `--microphone`)
/// stays on that device for as long as it is connected. Either way a microphone that
/// disappears never ends the recording: it moves to the default input, or failing that
/// the first input there is, and a picked one moves back when it returns. A change of
/// default output is reported too, as a stretch boundary for the alignment.
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

        public init(defaultInput: String?, inputs: [String], defaultOutput: String?) {
            self.defaultInput = defaultInput
            self.inputs = inputs
            self.defaultOutput = defaultOutput
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

        public var affected: [String] { switchRaw ? [CaptureTiming.microphoneStream] : [] }
    }

    public struct Move: Equatable, Sendable {
        public var from: String?
        public var to: String?
    }

    public let choice: Choice
    public let recordsRaw: Bool
    /// The device the microphone is recording now, and the default output.
    public private(set) var raw: String?
    public private(set) var output: String?

    /// The route as capture starts: the microphone on `target(for:)`.
    public init(choice: Choice, facts: Facts, recordsRaw: Bool = true) {
        self.choice = choice
        self.recordsRaw = recordsRaw
        raw = Self.target(for: choice, facts: facts, current: nil)
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
        guard inputMoved || outputMoved else { return nil }

        let reason: CaptureTiming.DeviceChange.Reason
        if inputMoved, let raw, !facts.inputs.contains(raw) {
            reason = .deviceGone
        } else if inputMoved, case .pinned(let picked) = choice, target == picked {
            reason = .deviceBack
        } else if inputMoved {
            reason = .defaultChanged
        } else {
            reason = .outputChanged
        }
        let change = Change(
            reason: reason,
            input: inputMoved ? Move(from: raw, to: target) : nil,
            output: outputMoved ? Move(from: output, to: facts.defaultOutput) : nil,
            switchRaw: switchRaw)
        raw = target
        output = facts.defaultOutput
        return change
    }
}
