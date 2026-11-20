import SwiftUI

struct RecipientPicker: View {
    let deliver: (SlackRecipients, SlackRecipient) async throws -> Void
    @State private var session = SlackRecipients()
    @State private var query = ""
    @State private var rows = [SlackRecipient]()
    @State private var selected: String?
    @State private var loading = true
    @State private var sending = false
    @State private var failure: String?
    @FocusState private var searching: Bool
    @Environment(\.dismiss) private var dismiss

    private var matches: [SlackRecipient] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { term.isEmpty || $0.name.localizedStandardContains(term) ||
            ($0.isChannel && ("#" + $0.name).localizedStandardContains(term)) }
    }

    private var destination: SlackRecipient? { matches.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            TextField("Search channels and people", text: $query)
                .textFieldStyle(.roundedBorder).focused($searching)
            List(selection: $selected) {
                section("Channels", rows: matches.filter(\.isChannel))
                section("Direct messages", rows: matches.filter { !$0.isChannel })
            }
            .frame(height: 260)
            .overlay {
                if loading { ProgressView().controlSize(.small) }
                else if matches.isEmpty && failure == nil {
                    Text(rows.isEmpty ? "No conversations in the Slack sidebar." : "No matches")
                        .foregroundStyle(.secondary)
                }
            }
            if let failure { Text(failure).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send", action: send).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(destination == nil || loading)
            }
        }
        .padding(16).frame(width: 410).disabled(sending)
        .interactiveDismissDisabled(sending)
        .onExitCommand { if !sending { dismiss() } }
        .task {
            searching = true
            do { rows = try await session.read() } catch { failure = error.localizedDescription }
            loading = false
        }
    }

    @ViewBuilder private func section(_ title: String, rows: [SlackRecipient]) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { row in Label(row.name, systemImage: row.symbol).tag(row.id) }
            }
        }
    }

    private func send() {
        guard !sending, let destination else { return }
        sending = true
        failure = nil
        Task {
            do {
                try await deliver(session, destination)
                dismiss()
            } catch {
                failure = error.localizedDescription
                if error is SlackSendUnconfirmed { selected = nil; rows = [] }
            }
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == SlackRecipients.bundle {
                NSApp.activate()
            }
            sending = false
        }
    }
}
