import AnyRecKit
import SwiftUI

/// How the selected transcript was reviewed, what could not be, and the way into every
/// version an engine wrote for this recording.
struct TranscriptReviewDetails: View {
    let directory: URL
    @State private var current: RecordingTranscript?
    @State private var sources: [TranscriptStore.SourceVersion] = []
    @State private var showsSources = false

    var body: some View {
        Group {
            if let current, current.reviewProvider != nil || sources.count > 1 || !current.reviewFailures.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Wording.reviewTitle(current)).font(.callout.bold())
                            Text(Wording.versions(sources)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("View Sources…") { showsSources = true }
                    }
                    ForEach(current.reviewFailures, id: \.self) { Notice($0, level: .advisory) }
                }
                .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .sheet(isPresented: $showsSources) { TranscriptSourcesView(sources: sources, failures: current.reviewFailures) }
            }
        }
        .task {
            current = RecordingTranscript.read(in: directory)
            sources = TranscriptStore.sources(in: directory)
        }
    }
}

private struct TranscriptSourcesView: View {
    let sources: [TranscriptStore.SourceVersion]
    let failures: [String]
    @State private var selected = 0
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Source Transcripts").font(.title2.bold())
            Picker("Version", selection: $selected) {
                ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                    Text(Wording.version(source)).tag(index)
                }
            }
            ScrollView {
                Text(text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            ForEach(failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 650, height: 550)
        .task(id: selected) {
            text = sources.indices.contains(selected) ? (Transcript.read(sources[selected].url)?.plainText ?? "") : ""
        }
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
                if let evidence = voice.identityEvidence, evidence.conflict {
                    Text("Speaker identity is uncertain").font(.caption.bold())
                    if let saved = evidence.voiceprintName {
                        Text("Saved voice: \(saved)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Call indicator: \(evidence.callNames.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
