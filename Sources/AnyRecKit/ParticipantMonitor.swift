import AppKit

final class ParticipantMonitor {
    private let selected: ParticipantAccessibility.Selection?
    private let allowDiscovery: Bool
    private let clock: () -> TimeInterval?
    private let queue = DispatchQueue(label: "ro.qlan.anyrec.participants", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var readers: [CGWindowID: ParticipantAccessibility] = [:]
    private var evidence = CallParticipants(observations: [])

    init(selection: ParticipantAccessibility.Selection?, allowDiscovery: Bool, clock: @escaping () -> TimeInterval?) {
        selected = selection
        self.allowDiscovery = allowDiscovery
        self.clock = clock
    }

    deinit { timer?.cancel() }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1)
            timer.setEventHandler { [weak self] in self?.scan() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() -> CallParticipants {
        queue.sync {
            timer?.cancel()
            timer = nil
            readers = [:]
            return evidence
        }
    }

    private func scan() {
        guard let start = clock() else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        let selections = selected.map { [$0] } ?? (allowDiscovery ? discover() : [])
        let ids = Set(selections.map(\.windowID))
        readers = readers.filter { ids.contains($0.key) }
        var snapshots: [(ParticipantAccessibility.Selection, ParticipantLabels.Snapshot)] = []
        for selection in selections {
            guard ProcessInfo.processInfo.systemUptime < deadline else { recordGap(at: start); return }
            if readers[selection.windowID] == nil {
                readers[selection.windowID] = ParticipantAccessibility(selection: selection)
            }
            guard let snapshot = readers[selection.windowID]?.snapshot(deadline: deadline) else {
                recordGap(at: start)
                return
            }
            if snapshot.hasCallControls, !snapshot.participants.isEmpty {
                snapshots.append((selection, snapshot))
            }
        }
        guard let end = clock(), end >= start, end - start <= 0.5,
              snapshots.count == 1, let (selection, snapshot) = snapshots.first else {
            recordGap(at: start)
            return
        }
        evidence.observations.append(.init(at: (start + end) / 2,
            source: "\(selection.bundleID):\(selection.processID):\(selection.windowID)",
            participants: snapshot.participants, speaking: snapshot.speaking))
    }

    private func recordGap(at time: TimeInterval) {
        evidence.observations.append(.init(at: time, source: "", participants: [], speaking: []))
    }

    private func discover() -> [ParticipantAccessibility.Selection] {
        let active = Set(AudioProcesses.snapshot().filter { $0.runningInput || $0.runningOutput }.map(\.bundleID))
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier, ParticipantLabels.Platform(bundleID: id) != nil else { return false }
            return active.contains { $0 == id || $0.hasPrefix(id + ".") }
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return windows.compactMap { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let app = apps.first(where: { $0.processIdentifier == pid }), let id = app.bundleIdentifier,
                  let windowID = window[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return ParticipantAccessibility.Selection(processID: pid, windowID: windowID, bundleID: id)
        }
    }
}
