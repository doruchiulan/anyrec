import AnyRecKit
import SwiftUI

struct EngineInfo: View {
    let engine: TranscriptionEngine
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Languages and guidance for \(Wording.engineName(engine))")
        .accessibilityLabel("About \(Wording.engineName(engine)): supported languages and guidance")
        .popover(isPresented: $presented, arrowEdge: .leading) {
            EngineLanguages(engine: engine)
        }
    }
}

private struct EngineLanguages: View {
    let engine: TranscriptionEngine
    @State private var query = ""

    private var languages: [String] {
        engine == .parakeet ? TranscriptionLanguages.parakeet : TranscriptionLanguages.whisper
    }

    private var filtered: [String] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? languages : languages.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Wording.engineName(engine)).font(.title2.bold())
            Text(engine == .parakeet
                 ? "Start with Parakeet if it supports your call's language. It is designed for fast transcription."
                 : "Choose Whisper for languages Parakeet doesn't support, or try it to compare transcription results.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Both run on this Mac. Accuracy varies with the language and recording.")
                .font(.callout).foregroundStyle(.secondary)
            Text(engine == .parakeet
                 ? "Automatic uses Parakeet once it is downloaded."
                 : "After downloading, select Whisper in Settings › Transcription to use it.")
                .font(.callout).foregroundStyle(.secondary)
            Text("\(languages.count) supported languages").font(.headline)
            TextField("Find a language", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                if filtered.isEmpty {
                    Text("No matching languages").foregroundStyle(.secondary).padding(.vertical, 16)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                        ForEach(filtered, id: \.self) { language in
                            Text(language).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(height: 240)
        }
        .padding(22)
        .frame(width: 400)
    }
}
