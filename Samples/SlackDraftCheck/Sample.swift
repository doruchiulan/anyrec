import SwiftUI

@main struct DraftCheck: App {
    var body: some Scene {
        Window("AnyRec · Slack sharing", id: "summary") {
            SampleSummary().padding(24).frame(width: 490)
        }.windowResizability(.contentSize)
    }
}

private let sampleText = """
Design review

We agreed to try a searchable recipient picker for meeting summaries.

Action item
Test sharing with a channel and a direct message.
"""

private struct SampleSummary: View {
    @State private var sharing = false
    @State private var previewRecipient: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sample meeting summary").font(.title2.bold())
            Text(sampleText).frame(maxWidth: .infinity, alignment: .leading)
            if let previewRecipient { Text("Local preview for " + previewRecipient) }
            Divider()
            HStack {
                Spacer()
                Button("Preview Slack picker…") { sharing = true }.buttonStyle(.borderedProminent)
            }
        }.sheet(isPresented: $sharing) {
            RecipientPicker { _, recipient in previewRecipient = recipient.name }
        }
    }
}
