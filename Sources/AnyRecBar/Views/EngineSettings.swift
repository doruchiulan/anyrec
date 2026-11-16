import AnyRecKit
import SwiftUI

struct EngineSettings: View {
    @Bindable var controller: RecordingController

    var body: some View {
        Section {
            ForEach(TranscriptionEngine.allCases.filter { $0 != .auto }, id: \.self) { engine in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(Wording.engineName(engine))
                            if engine == .parakeet || engine == .whisper { EngineInfo(engine: engine) }
                        }
                        Text(Wording.engineBlurb(engine)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    availability(engine)
                    Toggle(selectionLabel(engine), isOn: Binding(
                        get: { controller.isUsable(engine) },
                        set: { controller.enableEngine(engine, enabled: $0) }))
                        .labelsHidden().toggleStyle(.switch).fixedSize()
                        .disabled(!controller.readiness.of(engine).isReady)
                        .accessibilityLabel(selectionLabel(engine))
                        .help(selectionLabel(engine))
                }
                .accessibilityElement(children: .contain)
            }
        } header: {
            Text("Engines")
        } footer: {
            Text("Enable engines for transcription. An engine can be enabled once it is downloaded or set up. Automatic chooses one available on-device engine.")
                .settingsFooter()
        }
    }

    private func selectionLabel(_ engine: TranscriptionEngine) -> String {
        "Enable \(Wording.engineName(engine))"
    }

    @ViewBuilder private func availability(_ engine: TranscriptionEngine) -> some View {
        if engine == .openai {
            OpenAIKeyControl(controller: controller)
        } else if engine == .parakeet, !controller.readiness.of(engine).isReady {
            SetupControl(controller: controller, target: .parakeet, size: ParakeetSetup.downloadSize) {
                controller.installParakeet()
            }
        } else if engine == .whisper, !controller.readiness.of(engine).isReady {
            SetupControl(controller: controller, target: .whisper,
                         size: AssetDownload.describe(WhisperSetup.pending().reduce(0) { $0 + $1.bytes })) {
                controller.installWhisper()
            }
        } else {
            Status(text: Wording.engineStatus(engine, controller.readiness), ready: controller.readiness.of(engine).isReady)
        }
    }
}

struct TranscriptReviewSettings: View {
    @Bindable var controller: RecordingController

    /// What is typed, kept as typed so a comma just entered stays; the list is saved from it.
    @State private var vocabulary = ""

    var body: some View {
        Section {
            Toggle("Review transcripts with an LLM", isOn: $controller.transcriptionOptions.review)
            if controller.transcriptionOptions.review {
                Picker("Review with", selection: $controller.transcriptionOptions.reviewProvider) {
                    ForEach(SummaryProvider.allCases, id: \.self) { provider in
                        Text(provider.name).tag(provider)
                            .selectionDisabled(!controller.canSummarize(with: provider))
                    }
                }
                if !controller.canSummarize(with: controller.transcriptionOptions.reviewProvider) {
                    Text("Choose an available provider to review transcripts.").foregroundStyle(.secondary)
                }
                TextField(text: $vocabulary, prompt: Text("AnyRec, auto-record, Genie"), axis: .vertical) {
                    Text("Words to recognise")
                    Text("Product names, people and jargon, comma-separated. Review fixes garbled versions of them.")
                }
                .lineLimit(1...3)
                .onAppear { vocabulary = Vocabulary.text(controller.transcriptionOptions.vocabulary) }
                .onChange(of: vocabulary) { _, text in
                    let words = Vocabulary.words(text)
                    if words != controller.transcriptionOptions.vocabulary { controller.transcriptionOptions.vocabulary = words }
                }
            }
        } header: {
            Text("Transcript Review")
        } footer: {
            Text(controller.transcriptionOptions.review
                ? "Transcript text and speaker-name evidence are sent to \(controller.transcriptionOptions.reviewProvider.company). Review corrects recognition errors and resolves conflicting speaker names automatically, preserving how people spoke. Originals are kept; saved voiceprints stay unchanged."
                : "Optional transcript correction and automatic speaker conflict resolution, with an optional second engine to compare against.")
                .settingsFooter()
        }
    }
}
