import AnyRecKit
import SwiftUI

struct CopyTranscriptEditor: View {
    let directory: URL
    let original: Transcript
    let saved: () -> Void
    @State private var lines: [Utterance]
    @State private var selected = 0
    @State private var name = ""
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(directory: URL, transcript: Transcript, saved: @escaping () -> Void) {
        self.directory = directory
        original = transcript
        self.saved = saved
        _lines = State(initialValue: transcript.utterances)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit transcript").font(.headline)
            List(selection: $selected) {
                ForEach(lines.indices, id: \.self) { i in
                    Text(Wording.clock(lines[i].start) + "   " + lines[i].text).lineLimit(1).tag(i)
                }
            }
            if lines.indices.contains(selected) {
                HStack {
                    TextField("Speaker name", text: $name)
                    Button("Rename speaker") {
                        let speaker = lines[selected].speaker
                        for i in lines.indices where lines[i].speaker == speaker { lines[i].speaker = .named(cleanName) }
                    }.disabled(cleanName.isEmpty || cleanName == lines[selected].speaker.label)
                }
                TextEditor(text: $lines[selected].text).frame(height: 80)
            }
            if let failure { Text(failure) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try SharedCopy.edit(in: directory, original: original, lines: lines)
                        saved()
                        dismiss()
                    } catch { failure = error.localizedDescription }
                }.disabled(lines == original.utterances).keyboardShortcut(.defaultAction)
            }
        }.padding().frame(width: 520, height: 450)
            .onChange(of: selected, initial: true) { _, i in
                if lines.indices.contains(i) { name = lines[i].speaker.label }
            }
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}
