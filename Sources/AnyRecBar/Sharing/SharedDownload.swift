import AnyRecKit
import Foundation
import Observation

/// A shared recording's files on their way to this Mac: asked for when something needs
/// them, followed with the provider's own progress, for as long as it takes. Nothing here
/// opens a file that has not arrived, which would block whoever opened it.
@MainActor
@Observable
final class SharedDownload {
    enum State: Equatable {
        case idle
        /// Bytes so far and in all; `stalled` when none have come for a while.
        case downloading(done: Int64, total: Int64, stalled: Bool)
        /// In the team folder, but not uploaded from its owner's Mac yet.
        case waitingForOwner
        case failed(String)
    }

    private(set) var state = State.idle
    private var task: Task<Void, Never>?
    private var pending: (files: [URL], then: () -> Void)?
    private let progress = CloudProgress()
    static let patience: TimeInterval = 15

    static func isLocal(_ files: [URL]) -> Bool { files.allSatisfy { CloudFile.download($0) == .local } }

    /// Fetches `files`, then runs `then`. Asked again while it works, the later `then` wins
    /// and both sets of files are fetched.
    func fetch(_ files: [URL], then: @escaping () -> Void) {
        let files = (pending?.files ?? []) + files.filter { pending?.files.contains($0) != true }
        stop()
        pending = (files, then)
        progress.follow(files)
        task = Task { [weak self] in await self?.run(files) }
    }

    func retry() {
        guard let pending else { return }
        self.pending = nil
        fetch(pending.files, then: pending.then)
    }

    /// Stops waiting. The provider may still finish a file it has started.
    func cancel() {
        stop()
        pending = nil
        state = .idle
    }

    private func stop() {
        task?.cancel()
        task = nil
        progress.follow([])
    }

    private func run(_ files: [URL]) async {
        var requested: Set<URL> = []
        var last: Int64 = -1
        var moved = Date()
        while !Task.isCancelled {
            let facts = await Task.detached(priority: .userInitiated) {
                files.map { ($0, CloudFile.download($0), Wording.bytes(of: $0)) }
            }.value
            guard !Task.isCancelled else { return }
            if facts.allSatisfy({ $0.1 == .local }) {
                let then = pending?.then
                stop()
                pending = nil
                state = .idle
                then?()
                return
            }
            var missing = false
            for (file, status, _) in facts {
                switch status {
                case .local, .downloading: break
                case .missing: missing = true
                case .failed(let reason) where requested.contains(file):
                    stop()
                    state = .failed(reason)
                    return
                case .remote, .failed:
                    guard requested.insert(file).inserted else { break }
                    do { try CloudFile.requestDownload(file) } catch {
                        stop()
                        state = .failed(error.localizedDescription)
                        return
                    }
                }
            }
            if missing && facts.allSatisfy({ $0.1 == .missing || $0.1 == .local }) {
                set(.waitingForOwner)
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            let total = facts.reduce(Int64(0)) { $0 + $1.2 }
            let done = facts.reduce(Int64(0)) { sum, fact in
                sum + (fact.1 == .local ? fact.2 : Int64(Double(fact.2) * (progress.fractions[fact.0] ?? 0)))
            }
            if done != last {
                last = done
                moved = Date()
            }
            set(.downloading(done: done, total: total, stalled: Date().timeIntervalSince(moved) > Self.patience))
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func set(_ next: State) { if state != next { state = next } }
}
