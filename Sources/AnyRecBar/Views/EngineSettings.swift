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
                        get: { controller.transcriptionOptions.enabledEngines.contains(engine) },
                        set: { controller.enableEngine(engine, enabled: $0) }))
                        .labelsHidden().toggleStyle(.switch).fixedSize()
                        .accessibilityLabel(selectionLabel(engine))
                        .help(selectionLabel(engine))
                }
                .accessibilityElement(children: .contain)
            }
        } header: {
            Text("Engines")
        } footer: {
            Text("Enable engines for transcription. Automatic chooses one available on-device engine.")
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
            }
        } header: {
            Text("Transcript Review")
        } footer: {
            Text(controller.transcriptionOptions.review
                ? "Transcript text is sent to \(controller.transcriptionOptions.reviewProvider.company) to correct recognition errors and suggest speaker names. Aggregator results are compared. Originals are kept; names need your confirmation."
                : "Optional correction and speaker-name suggestions. Choose Aggregator above to let the reviewer compare transcripts.")
                .settingsFooter()
        }
    }
}
