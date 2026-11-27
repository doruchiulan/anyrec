import Foundation

/// The providers' own progress for files on their way up or down, as Finder's pie shows it:
/// a File Provider publishes a `Progress` for a file while it moves it.
@MainActor
final class CloudProgress {
    private(set) var fractions: [URL: Double] = [:]
    private var subscriptions: [URL: Any] = [:]

    /// Follows exactly `files`.
    func follow(_ files: some Collection<URL>) {
        let wanted = Set(files)
        for (file, subscription) in subscriptions where !wanted.contains(file) {
            Progress.removeSubscriber(subscription)
            subscriptions[file] = nil
            fractions[file] = nil
        }
        for file in wanted where subscriptions[file] == nil {
            subscriptions[file] = Progress.addSubscriber(forFileURL: file) { progress in
                let observation = progress.observe(\.fractionCompleted, options: [.initial]) { progress, _ in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        guard let self, self.subscriptions[file] != nil else { return }
                        self.fractions[file] = fraction
                    }
                }
                return {
                    observation.invalidate()
                    Task { @MainActor [weak self] in self?.fractions[file] = nil }
                }
            }
        }
    }
}
