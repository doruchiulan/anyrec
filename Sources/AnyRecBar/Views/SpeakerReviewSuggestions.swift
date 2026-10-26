import AnyRecKit
import SwiftUI

struct SpeakerReviewSuggestions: View {
    @Bindable var controller: RecordingController
    let entry: LibraryEntry
    @State private var review: TranscriptReview?
    @State private var transcript: Transcript?
    @State private var failure: String?
    @State private var deferred = false

    var body: some View {
        if let review, !review.speakerChanges.isEmpty, !deferred {
            VStack(alignment: .leading, spacing: 12) {
                Text("Suggested speaker corrections").font(.headline)
                Text("Check the context before applying. This changes the transcript and clears its previous summary.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(review.speakerChanges) { correction in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(correction.from.label) → \(correction.to.label)").font(.callout.bold())
                        if let transcript, transcript.utterances.indices.contains(correction.line) {
                            Text(transcript.utterances[correction.line].text).font(.callout).textSelection(.enabled)
                        }
                        Text(correction.reason).font(.caption)
                        Text("Evidence: “\(correction.quote)”").font(.caption).foregroundStyle(.secondary)
                        Button("Assign to \(correction.to.label)") { apply(correction) }
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

    private func load() {
        review = TranscriptReview.read(in: entry.directory)
        transcript = entry.transcript.flatMap(Transcript.read)
    }

    private func apply(_ correction: SpeakerCorrection) {
        guard !controller.working.contains(entry.directory), let file = entry.transcript else { return }
        do {
            try TranscriptSpeakerReview.apply(correction, to: file)
            Task { await controller.reloadLibrary() }
        } catch { failure = error.localizedDescription }
    }
}
