import AnyRecKit
import SwiftUI

/// Every line, laid out only as it scrolls into view, opening at the top and keeping the
/// line being played in view while the recording plays. Each row is told whether it is
/// the one playing, so moving the highlight redraws two rows, not a thousand.
struct TranscriptList: View {
    let lines: [Utterance]
    let meName: String?
    let playback: Playback
    let desk: SpeakerDesk?
    @Binding var filter: Speaker?

    var body: some View {
        let current = playback.currentLine
        let shown = filter.map { speaker in lines.indices.filter { lines[$0].speaker == speaker } } ?? Array(lines.indices)
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if filter != nil, shown.isEmpty {
                        VStack(spacing: 8) {
                            Text("No lines left here.").foregroundStyle(.secondary)
                            Button("Show All Lines") { filter = nil }
                        }
                        .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(shown, id: \.self) { index in
                        TranscriptRow(line: lines[index], index: index, isCurrent: index == current,
                                      meName: meName, desk: desk, playback: playback) {
                            playback.play(from: lines[index].start)
                        }
                        .equatable()
                        .id(index)
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.top)
            /// Only while playing: a click on a line seeks there, and scrolling away to read
            /// ahead while paused should not be undone.
            .onChange(of: current) { _, line in
                guard playback.isPlaying, let line, shown.contains(line) else { return }
                withAnimation { reader.scrollTo(line, anchor: .center) }
            }
        }
    }
}

private struct TranscriptRow: View, Equatable {
    let line: Utterance
    let index: Int
    let isCurrent: Bool
    let meName: String?
    let desk: SpeakerDesk?
    let playback: Playback
    let play: () -> Void
    @State private var choosing = false

    static func == (a: Self, b: Self) -> Bool {
        a.line == b.line && a.index == b.index && a.isCurrent == b.isCurrent && a.meName == b.meName && a.desk === b.desk
    }

    /// Lines nobody claimed read as the People panel and the filter call them.
    private var label: String { line.speaker == .others ? "Not sure who" : Wording.label(line.speaker, me: meName) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(Wording.clock(line.start), action: play)
                .buttonStyle(.plain)
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
                .accessibilityLabel("Play from \(Wording.clock(line.start))")
            VStack(alignment: .leading, spacing: 2) {
                /// The label opens the person picker for this line, the same one a Call line's
                /// button opens.
                Button { choosing = true } label: {
                    HStack(spacing: 6) {
                        Circle().fill(SpeakerColour.of(line.speaker)).frame(width: 8, height: 8)
                        Text(label).font(.caption.bold())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(desk == nil)
                .help(desk == nil ? "" : "Change who said this")
                .accessibilityLabel(desk == nil ? label : "\(label). Change who said this")
                .popover(isPresented: $choosing, arrowEdge: .leading) {
                    if let desk {
                        LinePersonPicker(desk: desk, line: index, playback: playback) { choosing = false }
                    }
                }
                Text(line.text).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
