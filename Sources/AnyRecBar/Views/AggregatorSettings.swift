import AnyRecKit
import SwiftUI

/// "Review with a second engine": which other engines a review compares the transcript
/// against. They run only when review is on; the chosen engine always writes the
/// transcript.
struct ComparisonSettings: View {
    @Bindable var controller: RecordingController

    var body: some View {
        Section {
            Toggle("Review with a second engine", isOn: $controller.transcriptionOptions.compareEngines)
                .disabled(!controller.transcriptionOptions.review)
            if controller.transcriptionOptions.compareEngines {
                ForEach(engines, id: \.self) { engine in
                    Toggle(Wording.engineName(engine), isOn: selection(engine))
                        .toggleStyle(.checkbox)
                        .disabled(!controller.transcriptionOptions.review)
                        .accessibilityLabel("Compare with \(Wording.engineName(engine))")
                }
                if engines.isEmpty {
                    Text("No engine is ready to compare against. Download one under Engines.")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(Wording.comparison(controller.transcriptionOptions))
                .settingsFooter()
        }
    }

    /// Only engines that are enabled and ready. One without its model is not listed.
    private var engines: [TranscriptionEngine] {
        TranscriptionEngine.allCases.filter { $0 != .auto && controller.isUsable($0) }
    }

    private func selection(_ engine: TranscriptionEngine) -> Binding<Bool> {
        Binding(
            get: { controller.transcriptionOptions.comparisonEngines.contains(engine) },
            set: { included in
                if included { controller.transcriptionOptions.comparisonEngines.insert(engine) }
                else { controller.transcriptionOptions.comparisonEngines.remove(engine) }
            })
    }
}
