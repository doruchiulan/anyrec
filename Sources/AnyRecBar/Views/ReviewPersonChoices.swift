import AnyRecKit
import SwiftUI

struct SomeoneElseButton: View {
    let desk: SpeakerDesk
    let title: String
    var exclude: Speaker?
    var offersMe = true
    var label = "Someone else…"
    let pick: (SpeakerDesk.PersonChoice) -> Void
    @State private var presented = false

    var body: some View {
        Button(label) { presented = true }
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                PersonPicker(desk: desk, title: title, current: nil, exclude: exclude, offersMe: offersMe, startsWithSearch: true) { choice in
                    presented = false
                    pick(choice)
                }
            }
    }
}

struct CorrectionRow: View {
    let fix: SpeakerCorrection
    let desk: SpeakerDesk
    let speakers: RecordingSpeakers
    let playback: Playback
    let names: [Speaker: String]
    let done: (String) -> Void
    @State private var showsReason = false

    private func name(_ speaker: Speaker) -> String { names[speaker] ?? speakers.label(speaker) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LineClip(line: fix.line, speakers: speakers, playback: playback)
            ViewThatFits(in: .horizontal) {
                HStack { change; Spacer(); actions }
                VStack(alignment: .leading, spacing: 4) { change; actions }
            }
            .font(.callout)
            if showsReason {
                Text(fix.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var change: some View {
        HStack(spacing: 6) {
            Text(name(fix.from)).strikethrough().foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            Text(name(fix.to)).bold()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Why?") { showsReason.toggle() }.buttonStyle(.link)
            SomeoneElseButton(desk: desk, title: "Who said this?", exclude: fix.from) { choice in
                desk.accept(fix, as: choice)
                if desk.failure == nil { done("Assigned to \(PersonPicker.describe(choice, in: speakers, names: names)).") }
            }
            Button("Leave") {
                desk.keep(fix)
                if desk.failure == nil { done("Left as it was.") }
            }
            Button("Fix") {
                desk.accept(fix)
                if desk.failure == nil { done("That line is now \(name(fix.to))'s.") }
            }
        }
        .controlSize(.small).fixedSize()
    }
}

struct SortLineChoices: View {
    let desk: SpeakerDesk
    let speakers: RecordingSpeakers
    let playback: Playback
    let source: Speaker
    let candidates: [String]
    let lines: [Int]
    let guesses: [Int: String]
    @Binding var picks: [Int: Speaker]
    @State private var shown = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines.prefix(shown), id: \.self) { line in
                LineClip(line: line, speakers: speakers, playback: playback)
                AnswerFlow(spacing: 6) {
                    let selected = picks[line] ?? speakers.speaker(named: guesses[line] ?? candidates[0])
                    ForEach(candidates, id: \.self) { name in
                        let target = speakers.speaker(named: name)
                        Button(Wording.firstName(name)) { picks[line] = target }
                            .tint(selected == target ? Color.accentColor : nil)
                            .accessibilityAddTraits(selected == target ? .isSelected : [])
                    }
                    SomeoneElseButton(desk: desk, title: "Who said this?", exclude: source) { choice in
                        picks[line] = choice.target(in: speakers)
                    }
                    if !candidates.contains(where: { speakers.speaker(named: $0) == selected }) {
                        Label(speakers.label(selected), systemImage: "checkmark")
                    }
                }
                .controlSize(.small)
            }
            if lines.count > shown {
                Button("Show More") { shown += 12 }.buttonStyle(.link).controlSize(.small)
            }
        }
    }
}
