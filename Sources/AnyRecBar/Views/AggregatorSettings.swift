import AnyRecKit
import SwiftUI

struct AggregatorSettings: View {
    @Bindable var controller: RecordingController

    var body: some View {
        Section {
            ForEach(TranscriptionEngine.allCases.filter { $0 != .auto }, id: \.self) { engine in
                Toggle(Wording.engineName(engine), isOn: selection(engine))
                    .toggleStyle(.checkbox)
                    .disabled(!controller.transcriptionOptions.enabledEngines.contains(engine))
                    .accessibilityLabel("Include \(Wording.engineName(engine)) in Aggregator")
            }
            if controller.transcriptionEngines(using: .aggregator).isEmpty {
                Text("Select at least one enabled, available engine to use Aggregator.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Aggregator engines")
        } footer: {
            Text("Selected engines run together. Unchecked engines remain available individually. Transcript review can combine the results.")
                .settingsFooter()
        }
    }

    private func selection(_ engine: TranscriptionEngine) -> Binding<Bool> {
        Binding(
            get: {
                controller.transcriptionOptions.enabledEngines.contains(engine)
                    && controller.transcriptionOptions.aggregatorEngines.contains(engine)
            },
            set: { included in
                if included { controller.transcriptionOptions.aggregatorEngines.insert(engine) }
                else { controller.transcriptionOptions.aggregatorEngines.remove(engine) }
            })
    }
}
