import AnyRecKit
import SwiftUI

struct SlackDraftButton: View {
    let title: String
    let summary: String?
    let audioOnly: Bool
    var linkFile: URL?
    @State private var presenting = false

    var body: some View {
        Button { presenting = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
            .disabled(summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
            .help("Share summary in Slack")
            .accessibilityLabel("Share in Slack…")
            .sheet(isPresented: $presenting) {
                RecipientPicker { session, recipient in
                    guard let summary else { throw CocoaError(.fileReadNoSuchFile) }
                    let message = DraftRecordingLink.message(title + "\n\n" + summary,
                                                           link: linkFile.flatMap(DraftRecordingLink.read), audioOnly: audioOnly)
                    try await session.send(recipient, text: message)
                }
            }
    }
}
