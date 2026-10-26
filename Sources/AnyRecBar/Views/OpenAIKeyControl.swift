import AnyRecKit
import SwiftUI

struct OpenAIKeyControl: View {
    @Bindable var controller: RecordingController
    @State private var presented = false

    var body: some View {
        Button(controller.readiness.of(.openai).isReady ? "API Key…" : "Add API Key…") {
            presented = true
        }
        .popover(isPresented: $presented, arrowEdge: .leading) {
            OpenAIKeyEditor(controller: controller)
        }
    }
}

private struct OpenAIKeyEditor: View {
    @Bindable var controller: RecordingController
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var saving = false
    @State private var submitted = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("OpenAI API Key").font(.headline)
            Text("Use your OpenAI key for cloud transcription and summaries.")
                .font(.callout).foregroundStyle(.secondary)
            if OpenAIKey.isFromEnvironment {
                Text("OPENAI_API_KEY from your environment takes precedence over a saved key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SecureField("API key", text: $key, prompt: Text("sk-…"))
                .textFieldStyle(.roundedBorder).focused($focused)
                .disabled(saving).onSubmit(save)
            if submitted, let outcome = controller.keyOutcome {
                Notice(Wording.keyOutcome(outcome), level: Wording.wasRefused(outcome) ? .error : .advisory)
            }
            HStack {
                Button("Done") { dismiss() }.disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(saving ? "Checking…" : "Save Key", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 340)
        .onAppear { focused = true }
    }

    private func save() {
        let entered = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saving, !entered.isEmpty else { return }
        key = ""
        saving = true
        submitted = false
        Task {
            await controller.saveOpenAIKey(entered)
            submitted = true
            saving = false
        }
    }
}
