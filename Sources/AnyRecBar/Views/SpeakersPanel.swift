import AnyRecKit
import SwiftUI

/// Me is the accent; everyone else gets a fixed hue per letter or name so a voice keeps
/// its colour down the page and across recordings.
enum SpeakerColour {
    static func of(_ speaker: Speaker) -> Color {
        switch speaker {
        case .me: return .accentColor
        case .others: return .purple
        case .voice(let letter), .named(let letter):
            let palette: [Color] = [.purple, .orange, .teal, .pink, .indigo, .mint]
            return palette[Int(letter.unicodeScalars.reduce(0) { $0 + $1.value }) % palette.count]
        }
    }
}

/// Up to three clips of one speaker; each plays its span and stops.
struct ClipButtons: View {
    let clips: [SpeakerClip]
    let playback: Playback

    var body: some View {
        HStack(spacing: 6) {
            ForEach(clips, id: \.self) { clip in
                ClipButton(clip: clip, playback: playback)
            }
        }
    }
}

/// Reads `playingClip`, which changes once a clip, never the playhead.
private struct ClipButton: View {
    let clip: SpeakerClip
    let playback: Playback

    var body: some View {
        let playing = playback.playingClip == clip
        Button { playback.play(clip) } label: {
            Label(Wording.clock(clip.start), systemImage: playing ? "stop.fill" : "play.fill")
                .monospacedDigit()
        }
        .controlSize(.small)
        .help(Wording.clip(clip))
        .accessibilityLabel(playing ? "Stop" : Wording.clip(clip))
    }
}

/// Who said one line: what a transcript label opens. The person picker with the line's
/// words and a play button on top; the choice moves that line and nothing else.
struct LinePersonPicker: View {
    let desk: SpeakerDesk
    let line: Int
    let playback: Playback
    let done: () -> Void

    var body: some View {
        if let speakers = desk.speakers, speakers.lines.indices.contains(line) {
            let utterance = speakers.lines[line]
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ClipButtons(clips: [SpeakerClip.of(utterance, index: line)], playback: playback)
                    Text("“\(utterance.text)”").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding([.horizontal, .top], 12)
                PersonPicker(desk: desk, title: nil, current: utterance.speaker, exclude: nil, offersMe: true) { choice in
                    desk.assignLines([line], to: choice)
                    done()
                }
            }
        } else {
            ProgressView().padding()
        }
    }
}

/// Who someone is, or who said something: everyone in the call — the people speaking in
/// this recording and whoever else the call window showed, the current one ticked — then
/// Me, apart, where it makes sense, then Someone else…, the voice library with a search
/// field and a way to add a new person. One click answers. It replaced a popover with two
/// sections that read alike — names that renamed, speakers that took the line — where a
/// speaker in the call appeared only in the second.
struct PersonPicker: View {
    let desk: SpeakerDesk
    let title: String?
    let current: Speaker?
    let exclude: Speaker?
    let offersMe: Bool
    var startsWithSearch = false
    let pick: (SpeakerDesk.PersonChoice) -> Void

    var body: some View {
        if let speakers = desk.speakers {
            PersonPickerContent(speakers: speakers, title: title, current: current, exclude: exclude,
                                offersMe: offersMe, startsWithSearch: startsWithSearch, pick: pick)
                .disabled(desk.busy)
        } else {
            ProgressView().padding()
        }
    }

    /// How an answer reads in a sentence.
    static func describe(_ choice: SpeakerDesk.PersonChoice, in speakers: RecordingSpeakers, names: [Speaker: String]) -> String {
        switch choice {
        case .speaker(.me): "you"
        case .speaker(let speaker): names[speaker] ?? speakers.label(speaker)
        case .name(let name, _): name
        }
    }

}

struct PersonPickerContent: View {
    let speakers: RecordingSpeakers
    let title: String?
    let current: Speaker?
    let exclude: Speaker?
    let offersMe: Bool
    let startsWithSearch: Bool
    let pick: (SpeakerDesk.PersonChoice) -> Void
    @State private var browsing = false
    @State private var query = ""
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline) }
            if browsing || startsWithSearch { library(speakers) } else { inCall(speakers) }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    private func inCall(_ speakers: RecordingSpeakers, offerSearch: Bool = true) -> some View {
        let choices = speakers.lineChoices
        let matches = { (name: String) in query.isEmpty || name.localizedCaseInsensitiveContains(query) }
        let people = choices.speakers.filter { $0 != .me && $0 != exclude && matches(speakers.label($0)) }
        let roster = choices.callNames.filter(matches)
        let me = offersMe && exclude != .me && (matches("Me") || matches(speakers.label(.me)))
        return VStack(alignment: .leading, spacing: 2) {
            if !people.isEmpty || !roster.isEmpty || me || current == .others {
                Text("In this call").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
            if current == .others {
                PersonRow(name: "Not sure who", hint: nil, ticked: true) {}
            }
            ForEach(people, id: \.self) { speaker in
                PersonRow(name: speakers.label(speaker), hint: nil, ticked: speaker == current) { choose(.speaker(speaker)) }
            }
            ForEach(roster, id: \.self) { name in
                PersonRow(name: name, hint: nil, ticked: false) { choose(.name(name, person: nil)) }
            }
            if me {
                Divider().padding(.vertical, 4)
                PersonRow(name: "Me", hint: speakers.row(for: .me)?.name, ticked: current == .me) { choose(.speaker(.me)) }
            }
            if offerSearch {
                Divider().padding(.vertical, 4)
                PersonRow(name: "Someone else…", hint: nil, ticked: false, chevron: true) {
                    browsing = true
                    searching = true
                }
            }
        }
    }

    private func library(_ speakers: RecordingSpeakers) -> some View {
        let text = query.trimmingCharacters(in: .whitespaces)
        let all = speakers.lineChoices.library
        let savedNames = Set(all.map(\.savedName))
        let shown = text.isEmpty ? all : speakers.completions(for: .others, typing: text, limit: .max)
            .filter { savedNames.contains($0.savedName) || $0.exact }
        let exact = speakers.person(for: .others, typed: text)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !startsWithSearch {
                    Button { browsing = false; query = "" } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless).accessibilityLabel("Back to the people in this call")
                }
                TextField("Type a name", text: $query)
                    .textFieldStyle(.roundedBorder).controlSize(.small).focused($searching)
                    .onSubmit { if !text.isEmpty { choose(.name(exact?.shownName ?? text, person: exact?.savedName)) } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if startsWithSearch || !text.isEmpty {
                        inCall(speakers, offerSearch: false)
                        Divider()
                    }
                    if !shown.isEmpty {
                        Text("From earlier calls").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
                    }
                    ForEach(shown) { person in
                        PersonRow(name: person.shownName, hint: nil, ticked: false) { choose(.name(person.shownName, person: person.savedName)) }
                    }
                    if !text.isEmpty, exact == nil, speakers.row(for: speakers.speaker(named: text)) == nil,
                       !speakers.lineChoices.callNames.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                        PersonRow(name: "New person “\(text)”", hint: nil, ticked: false) { choose(.name(text, person: nil)) }
                    }
                    if shown.isEmpty, text.isEmpty {
                        Text("Nobody else is known yet. Type a name to add someone.").font(.callout).foregroundStyle(.secondary).padding(6)
                    }
                }
            }
            .frame(maxHeight: 240)
            .onAppear { searching = true }
        }
    }

    private func choose(_ choice: SpeakerDesk.PersonChoice) {
        let target = choice.target(in: speakers)
        guard target != current, target != exclude, offersMe || target != .me else { return }
        if speakers.row(for: target) != nil {
            pick(.speaker(target))
            return
        }
        pick(choice)
    }
}

/// One person in the picker: a full-width row that highlights under the pointer, ticked when
/// it is who the line has now.
private struct PersonRow: View {
    let name: String
    let hint: String?
    let ticked: Bool
    var chevron = false
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.caption.bold()).opacity(ticked ? 1 : 0).accessibilityHidden(!ticked)
                Text(name).lineLimit(1)
                Spacer(minLength: 8)
                if let hint { Text(hint).font(.caption).foregroundStyle(hovering ? Color.white.opacity(0.85) : .secondary) }
                if chevron { Image(systemName: "chevron.right").font(.caption).foregroundStyle(hovering ? .white : .secondary) }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(ticked ? .isSelected : [])
    }
}
