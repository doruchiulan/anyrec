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
                ForEach(TranscriptionEngine.allCases.filter { $0 != .auto }, id: \.self) { engine in
                    Toggle(Wording.engineName(engine), isOn: selection(engine))
                        .toggleStyle(.checkbox)
                        .disabled(!controller.transcriptionOptions.enabledEngines.contains(engine)
                                  || !controller.transcriptionOptions.review)
                        .accessibilityLabel("Compare with \(Wording.engineName(engine))")
                }
            }
        } footer: {
            Text(Wording.comparison(controller.transcriptionOptions))
                .settingsFooter()
        }
    }

    private func selection(_ engine: TranscriptionEngine) -> Binding<Bool> {
        Binding(
            get: {
                controller.transcriptionOptions.enabledEngines.contains(engine)
                    && controller.transcriptionOptions.comparisonEngines.contains(engine)
            },
            set: { included in
                if included { controller.transcriptionOptions.comparisonEngines.insert(engine) }
                else { controller.transcriptionOptions.comparisonEngines.remove(engine) }
            })
    }
}
