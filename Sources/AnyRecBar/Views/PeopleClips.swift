import AnyRecKit
import SwiftUI

// MARK: - Pieces

/// A round badge: initials, "?" or a count, in the person's colour.
struct Avatar: View {
    let text: String
    let colour: Color
    var large = false

    var body: some View {
        Text(text)
            .font(large ? .callout.bold() : .caption.bold())
            .foregroundStyle(colour)
            .frame(width: large ? 38 : 28, height: large ? 38 : 28)
            .background(colour.opacity(0.18), in: Circle())
            .accessibilityHidden(true)
    }
}

struct NotThem {
    let label: String
    let speaker: Speaker
    let desk: SpeakerDesk
    let done: (String) -> Void
}

/// A person's few seconds, each playable, with what was said.
struct ClipList: View {
    let clips: [SpeakerClip]
    let speakers: RecordingSpeakers
    let playback: Playback
    var notThem: NotThem? = nil

    var body: some View {
        VStack(spacing: 4) {
            ForEach(clips, id: \.self) { clip in ClipLine(clip: clip, speakers: speakers, playback: playback, notThem: notThem) }
        }
    }
}

/// One line as a playable row.
struct LineClip: View {
    let line: Int
    let speakers: RecordingSpeakers
    let playback: Playback

    var body: some View {
        if speakers.lines.indices.contains(line) {
            ClipLine(clip: SpeakerClip.of(speakers.lines[line], index: line), speakers: speakers, playback: playback)
        }
    }
}

/// Reads `playingClip`, which changes once a clip, never the playhead.
struct ClipLine: View {
    let clip: SpeakerClip
    let speakers: RecordingSpeakers
    let playback: Playback
    var notThem: NotThem? = nil
    @State private var picking = false

    var body: some View {
        HStack(spacing: 6) {
            play
            if let notThem {
                Button(notThem.label) { picking = true }
                    .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
                    .help("This one isn't them: say who it is. Only this line moves.")
                    .popover(isPresented: $picking, arrowEdge: .trailing) {
                        PersonPicker(desk: notThem.desk, title: "Who said this?", current: notThem.speaker, exclude: nil, offersMe: true) { choice in
                            picking = false
                            notThem.desk.assignLines([clip.line], to: choice)
                            notThem.done("That line is now \(PersonPicker.describe(choice, in: speakers, names: [:]))'s.")
                        }
                    }
            }
        }
    }

    private var play: some View {
        let playing = playback.playingClip == clip
        return Button { playback.play(clip) } label: {
            HStack(spacing: 8) {
                Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 9))
                    .foregroundStyle(.white).frame(width: 20, height: 20)
                    .background(playing ? Color.green : Color.accentColor, in: Circle())
                Text(speakers.lines.indices.contains(clip.line) ? "“\(speakers.lines[clip.line].text)”" : "")
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(Wording.clock(clip.start)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playing ? "Stop" : Wording.clip(clip))
    }
}

/// Buttons side by side at their own widths, wrapping onto a new row when the next one does
/// not fit.
struct AnswerFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty { rows.append(Row()) }
            let last = rows.count - 1
            rows[last].width = rows[last].items.isEmpty ? size.width : rows[last].width + spacing + size.width
            rows[last].height = max(rows[last].height, size.height)
            rows[last].items.append(index)
        }
        return rows
    }
}
