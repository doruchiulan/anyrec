import AnyRecKit
import Foundation
import IOKit.ps
import Observation

/// Runs `Compression` over the library in the background, one recording at a time,
/// newest first, and only while it cannot get in anyone's way: nothing being recorded,
/// started or saved, no merge, transcript or summary running, and the Mac on power.
///
/// x265 takes about 0.4 of the call's length on a 1600-pixel window, on a third of the
/// cores, so it is never allowed near a recording: the moment one
/// starts (or the Mac goes on battery, or the setting is switched off) ffmpeg is stopped
/// and the recording is simply picked up again later. A compression is not background
/// work in the sense Quit and updates wait for — it is stopped, not waited for.
@MainActor
@Observable
final class Compressor {
    /// The recording being compressed now.
    private(set) var current: URL?
    /// Recordings that still have it to come.
    private(set) var waiting = 0
    /// Bytes saved since launch.
    private(set) var saved: Int64 = 0

    @ObservationIgnored private weak var controller: RecordingController?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Failed this launch: not tried again until the next one.
    @ObservationIgnored private var failed: Set<URL> = []

    init(controller: RecordingController) {
        self.controller = controller
    }

    func start() {
        guard loop == nil else { return }
        /// Looking for work reads every recording's `recording.json`, so it happens every
        /// 30 s; while ffmpeg runs, whether it may go on is checked every 2 s.
        loop = Task { [weak self] in
            var idle = 0
            while !Task.isCancelled {
                if self?.work != nil || idle == 0 { await self?.tick() }
                idle = (idle + 1) % 15
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Stops ffmpeg now: quitting, or the recording is being moved to the Trash.
    func stop(_ directory: URL? = nil) {
        guard directory == nil || directory == current else { return }
        work?.cancel()
    }

    private var allowed: Bool {
        guard let controller, controller.compressesRecordings, !controller.isQuitting else { return false }
        let busy = controller.phase == .starting || controller.phase == .recording || controller.phase == .stopping
        return !busy && controller.working.isEmpty && Self.onPower
    }

    private func tick() async {
        guard let controller else { return }
        if work != nil {
            if !allowed { work?.cancel() }
            return
        }
        let candidates = controller.library.map(\.directory).filter {
            !failed.contains($0) && Compression.candidate(in: $0) != nil
        }
        waiting = candidates.count
        guard allowed, let next = candidates.first, let ffmpeg = Muxer.ffmpegPath() else { return }
        for leftover in Compression.leftovers(in: next) { try? FileManager.default.removeItem(at: leftover) }

        current = next
        work = Task.detached(priority: .utility) { [weak self] in
            let outcome: Result<Compression.Outcome, Error>
            do { outcome = .success(try await Compression.compress(next, using: ffmpeg)) }
            catch { outcome = .failure(error) }
            await self?.finished(next, outcome)
        }
    }

    private func finished(_ directory: URL, _ outcome: Result<Compression.Outcome, Error>) async {
        switch outcome {
        case .success(.compressed(let before, let after)):
            saved += before - after
        case .success(.notWorthwhile):
            break
        case .failure(let error):
            /// Stopped on purpose: tried again once it is allowed. Anything else waits for
            /// the next launch rather than burning another twenty minutes now.
            if !(error is CancellationError) {
                failed.insert(directory)
                NSLog("AnyRec: compressing \(directory.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }
        current = nil
        work = nil
        await controller?.reloadLibrary()
    }

    /// On mains power, or a Mac that has no battery. Read each time: it changes.
    static var onPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return true }
        return source == kIOPMACPowerKey
    }
}
