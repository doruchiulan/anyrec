import AnyRecKit
import SwiftUI

struct TranscriptReviewDetails: View {
    let directory: URL
    @State private var review: TranscriptReview?
    @State private var showsSources = false

    var body: some View {
        Group {
            if let review, review.provider != nil || review.sources.count > 1 || !review.failures.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(review.provider.map { "Reviewed with \($0.name)" } ?? (review.failures.isEmpty ? "Aggregator transcription" : "Original transcript retained"))
                            .font(.callout.bold())
                        Text("\(review.sources.count) source transcript\(review.sources.count == 1 ? "" : "s") retained")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("View Sources…") { showsSources = true }
                }
                ForEach(review.failures, id: \.self) { Notice($0, level: .advisory) }
                }
                .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .sheet(isPresented: $showsSources) { TranscriptSourcesView(review: review) }
            }
        }
        .task { review = TranscriptReview.read(in: directory) }
    }
}

private struct TranscriptSourcesView: View {
    let review: TranscriptReview
    @State private var selected = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Source Transcripts").font(.title2.bold())
            Picker("Engine", selection: $selected) {
                ForEach(Array(review.sources.enumerated()), id: \.offset) { index, source in
                    Text(source.engine.capitalized + (index == 0 ? " · Original" : "")).tag(index)
                }
            }
            ScrollView {
                Text(review.sources[selected].plainText).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            ForEach(review.failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 650, height: 550)
    }
}

struct SpeakerNamingCard: View {
    let voice: RecordingVoices.Voice
    @Binding var name: String
    let suggestion: SpeakerSuggestion?
    let colour: Color
    let play: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: play) {
                Image(systemName: "play.fill").font(.system(size: 10))
                    .frame(width: 28, height: 28)
                    .background(colour.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain).accessibilityLabel("Play a sample of speaker \(voice.letter)")
            VStack(alignment: .leading, spacing: 5) {
                Text("“\(voice.sample)”").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                TextField("Name speaker \(voice.letter)…", text: $name)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                if let suggestion {
                    Text("Suggested: \(suggestion.name)").font(.caption.bold())
                    Text("“\(suggestion.quote)”").font(.caption).foregroundStyle(.secondary)
                    Button("Use suggestion") { name = suggestion.name }.controlSize(.small)
                }
            }
        }
        .padding(8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}
