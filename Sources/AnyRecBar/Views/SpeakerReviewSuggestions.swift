import AnyRecKit
import SwiftUI

/// Speaker corrections the review proposed, one confirmation each. Accepting one changes
/// that line's speaker and nothing else; the summary stays and says it is stale.
struct SpeakerReviewSuggestions: View {
    @Bindable var controller: RecordingController
    let entry: LibraryEntry
    @State private var current: RecordingTranscript?
    @State private var failure: String?
    @State private var deferred = false

    var body: some View {
        if let current, !current.pendingSpeakerChanges.isEmpty, !deferred {
            VStack(alignment: .leading, spacing: 12) {
                Text("Suggested speaker corrections").font(.headline)
                Text("Check the context before applying. Only that line’s speaker changes.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(current.pendingSpeakerChanges) { correction in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(label(correction.from)) → \(label(correction.to))").font(.callout.bold())
                        if current.transcript.utterances.indices.contains(correction.line) {
                            Text(current.transcript.utterances[correction.line].text).font(.callout).textSelection(.enabled)
                        }
                        Text(correction.reason).font(.caption)
                        Text("Evidence: “\(correction.quote)”").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Assign to \(label(correction.to))") { apply(correction) }
                            Button("Keep \(label(correction.from))") { dismiss(correction) }.buttonStyle(.borderless)
                        }
                    }
                }
                if let failure { Notice(failure, level: .error) }
                Button("Not now") { deferred = true }.buttonStyle(.borderless)
            }
            .padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
            .disabled(controller.working.contains(entry.directory))
        } else {
            Color.clear.frame(height: 0).task { load() }
        }
    }

    private func label(_ speaker: Speaker) -> String {
        if case .voice(let letter) = speaker, let name = current?.voices?.names[letter] { return name }
        return speaker.label
    }

    private func load() {
        current = RecordingTranscript.read(in: entry.directory)
    }

    private func apply(_ correction: SpeakerCorrection) {
        guard !controller.working.contains(entry.directory) else { return }
        do {
            try TranscriptSpeakerReview.apply(correction, in: entry.directory)
            load()
            Task { await controller.reloadLibrary() }
        } catch { failure = error.localizedDescription }
    }

    private func dismiss(_ correction: SpeakerCorrection) {
        do {
            try TranscriptSpeakerReview.dismiss(correction, in: entry.directory)
            load()
        } catch { failure = error.localizedDescription }
    }
}
