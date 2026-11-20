import SwiftUI
import UniformTypeIdentifiers

struct RecordingLinkEditor: View {
    let link: URL?
    let copies: [URL]
    let save: (URL?) throws -> Void
    @State private var input: String
    @State private var fetching = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(link: URL?, copies: [URL], save: @escaping (URL?) throws -> Void) {
        self.link = link
        self.copies = copies
        self.save = save
        _input = State(initialValue: link?.absoluteString ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recording link").font(.headline)
            Text("Use OneDrive’s Copy Link in Finder, or paste a sharing link.")
            finderButton
            TextField("https://…", text: $input)
            if fetching { ProgressView("Waiting for OneDrive…").controlSize(.small) }
            if let failure { Text(failure).foregroundStyle(.secondary) }
            HStack {
                if link != nil { Button("Remove link") { apply(nil) } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save link") { if let url = DraftRecordingLink.parse(input) { apply(url) } }
                    .disabled(DraftRecordingLink.parse(input) == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 390).disabled(fetching).interactiveDismissDisabled(fetching)
    }

    @ViewBuilder private var finderButton: some View {
        let files = copies.filter { FinderRecordingLink.oneDriveRoot(for: $0) != nil }
        if files.count == 1, let file = files.first {
            Button("Get OneDrive link from Finder") { fetch(file) }
        } else if files.isEmpty {
            Button("Choose file in OneDrive…") { chooseFile() }
        } else {
            Menu("Get OneDrive link from Finder") {
                ForEach(files, id: \.self) { file in
                    Button(FinderRecordingLink.oneDriveRoot(for: file)?.lastPathComponent ?? file.lastPathComponent) { fetch(file) }
                }
            }
        }
        if let other = copies.first(where: { FinderRecordingLink.oneDriveRoot(for: $0) == nil }) {
            Button("Show cloud copy in Finder") { NSWorkspace.shared.activateFileViewerSelecting([other]) }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose the uploaded recording or audio"
        panel.prompt = "Get OneDrive Link"
        panel.allowedContentTypes = [.movie, .audio]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        if panel.runModal() == .OK, let file = panel.url { fetch(file) }
    }

    private func fetch(_ file: URL) {
        failure = nil
        fetching = true
        Task {
            do { input = try await FinderRecordingLink.fetch(file).absoluteString }
            catch { failure = error.localizedDescription }
            fetching = false
            NSApp.activate()
        }
    }

    private func apply(_ value: URL?) {
        do { try save(value) } catch { failure = "Couldn’t save the recording link. \(error.localizedDescription)" }
    }
}
