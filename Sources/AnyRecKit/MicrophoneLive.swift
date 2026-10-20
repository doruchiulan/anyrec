import Foundation

/// When the call could hear the microphone.
///
/// Mute lives inside the call app. Some apps release the microphone when it is
/// pressed, and Core Audio then shows them running no input; Teams holds it open and
/// feeds it silence, and says so only on its own mute button. Both are read, and
/// anything the microphone picked up outside these spans reached nobody — a word to
/// someone in the room, a cough, a keyboard — and has no business in the mix or
/// under "Me".
public struct MicrophoneLive: Sendable, Equatable {
    public struct Transition: Sendable, Equatable {
        public let at: TimeInterval
        public let live: Bool

        public init(at: TimeInterval, live: Bool) {
            self.at = at
            self.live = live
        }
    }

    /// How long the recording ran, so the muted time can be said.
    public let duration: TimeInterval
    /// Seconds from the start of the recording.
    public let spans: [Range<TimeInterval>]

    public init(duration: TimeInterval, spans: [Range<TimeInterval>]) {
        self.duration = duration
        self.spans = spans
    }

    /// A recording opens with the call not listening — the first scan says otherwise
    /// at once if it is — and the last span closes when the recording does.
    public init(duration: TimeInterval, transitions: [Transition]) {
        var spans: [Range<TimeInterval>] = []
        var opened: TimeInterval?
        for transition in transitions {
            if transition.live {
                if opened == nil { opened = transition.at }
            } else if let start = opened {
                if transition.at > start { spans.append(start..<transition.at) }
                opened = nil
            }
        }
        if let start = opened, duration > start { spans.append(start..<duration) }
        self.init(duration: duration, spans: spans)
    }

    public var total: TimeInterval {
        spans.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// Worth saying only when the call was deaf to the microphone for a real stretch.
    public var note: String? {
        let muted = duration - total
        guard muted >= 1 else { return nil }
        return
            "The call was not listening to the microphone for \(Self.clock(muted)) of "
            + "\(Self.clock(duration)) — muted, or not yet in the call — so the microphone "
            + "is silent in call.mp4 and in the transcript for that time. Nothing on it "
            + "reached anyone."
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        let (hours, minutes, rest) = (whole / 3600, whole % 3600 / 60, whole % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    // MARK: - On disk

    /// `{"duration": 290.2, "live": [[12.0, 45.5], …]}`, next to the tracks.
    private struct File: Codable {
        var duration: TimeInterval
        var live: [[TimeInterval]]
    }

    public static func read(_ url: URL) -> MicrophoneLive? {
        guard let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else { return nil }
        let spans = file.live.compactMap { pair -> Range<TimeInterval>? in
            guard pair.count == 2, pair[0] < pair[1] else { return nil }
            return pair[0]..<pair[1]
        }
        return MicrophoneLive(duration: file.duration, spans: spans)
    }

    public func write(to url: URL) throws {
        let file = File(duration: duration, live: spans.map { [$0.lowerBound, $0.upperBound] })
        try JSONEncoder().encode(file).write(to: url, options: .atomic)
    }
}

extension MicrophoneLive {
    /// Watches the call apps for the length of a recording: four reads a second of
    /// the HAL's process list and of each app's mute button, on its own queue.
    ///
    /// Polled rather than listened for. A property listener would place a transition
    /// to the millisecond, but mute is pressed by a hand, and a quarter second is
    /// already finer than the gap between the clock starting and the first buffer.
    public final class Monitor {
        static let interval: TimeInterval = 0.25

        private let watched: [String: MuteButton?]
        private var readers: [String: MuteButton.Reader] = [:]
        private let queue = DispatchQueue(label: "ro.qlan.anyrec.microphone-live")
        private var timer: DispatchSourceTimer?
        private var startedAt = Date()
        private var live = false
        private var sawCall = false
        private var transitions: [Transition] = []

        /// Each watched bundle id, with its mute button when anyrec knows how to read
        /// it. A browser's audio runs in a helper with the browser's id and a suffix,
        /// so a watched id also covers everything under it.
        public init(watching apps: [String: MuteButton?]) {
            watched = apps
        }

        deinit { timer?.cancel() }

        public func start() {
            queue.sync {
                startedAt = Date()
                live = false
                sawCall = false
                transitions = []
                scan()

                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
                timer.setEventHandler { [weak self] in self?.scan() }
                timer.resume()
                self.timer = timer
            }
        }

        /// Nil when no watched app did any audio for the whole recording. A call
        /// nobody saw is not a call that was muted, and the microphone is left alone.
        public func stop() -> MicrophoneLive? {
            queue.sync {
                timer?.cancel()
                timer = nil
                scan()
                guard sawCall else { return nil }
                return MicrophoneLive(duration: elapsed, transitions: transitions)
            }
        }

        private var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

        /// The call is listening when a watched app runs microphone input and its own
        /// button, if it has one on screen, does not say muted.
        private func scan() {
            var running: [String: [AudioProcess]] = [:]
            for process in AudioProcesses.snapshot() {
                guard
                    let id = watched.keys.first(where: {
                        process.bundleID == $0 || process.bundleID.hasPrefix($0 + ".")
                    })
                else { continue }
                running[id, default: []].append(process)
            }

            let active = running.filter { entry in
                entry.value.contains { $0.runningInput || $0.runningOutput }
            }
            if !active.isEmpty { sawCall = true }
            let listening = active.contains { id, processes in
                processes.contains(where: \.runningInput) && !(reader(for: id)?.muted() ?? false)
            }

            guard listening != live else { return }
            live = listening
            transitions.append(Transition(at: elapsed, live: listening))
        }

        /// Made the first time the app is heard doing audio, kept for the recording.
        private func reader(for id: String) -> MuteButton.Reader? {
            if let reader = readers[id] { return reader }
            guard let button = watched[id] ?? nil,
                let reader = MuteButton.Reader(bundleID: id, button: button)
            else { return nil }
            readers[id] = reader
            return reader
        }
    }
}
