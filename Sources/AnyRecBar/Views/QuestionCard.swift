import AnyRecKit
import SwiftUI

// MARK: - One question

struct QuestionCard: View {
    let question: RecordingSpeakers.Question
    let position: Int
    let count: Int
    let desk: SpeakerDesk
    let speakers: RecordingSpeakers
    let playback: Playback
    let app: String?
    let names: [Speaker: String]
    let done: (String) -> Void
    let skip: (String) -> Void
    let move: (Int) -> Void
    let listen: () -> Void
    /// What asking the review's model about the unclaimed lines came to.
    let asked: (String) -> Void
    @State private var picks: [Int: Speaker] = [:]
    @State private var shownFixes = 3
    /// Lines answered on this card, hidden at once rather than when the transcript is read again.
    @State private var answeredLines: Set<Int> = []
    @State private var allLines = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Avatar(text: badge, colour: badgeColour, large: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.bold())
                    if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
                if count > 1 {
                    HStack(spacing: 2) {
                        Button { move(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                            .accessibilityLabel("Previous question")
                        Text("\(position + 1) of \(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Button { move(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                            .accessibilityLabel("Next question")
                    }
                }
            }
            content
            answers
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func name(_ speaker: Speaker) -> String { names[speaker] ?? speakers.label(speaker) }

    /// On each sample: the question's own person, as the question names them.
    private var notLabel: String {
        switch question.kind {
        case .wasYou: "Not you?"
        case .confirm(_, let candidate): "Not \(Wording.firstName(candidate))?"
        default: "Not them?"
        }
    }

    // MARK: Wording

    private var title: String {
        switch question.kind {
        case .wasYou: "Was this you?"
        case .who: "Who is this?"
        case .confirm(_, let name): "Is this \(name)?"
        case .samePerson: "Are these the same person?"
        case .sort(_, let names, _, _): names.map(Wording.firstName).joined(separator: " or ") + "?"
        case .eachLine(_, let lines, _, _): lines.count == 1 ? "Who said this?" : "Who said each of these?"
        case .unnamedBits(let lines, let seconds, _):
            seconds < 60 ? "\(lines.count) short \(lines.count == 1 ? "bit doesn't" : "bits don't") have a name"
                : "\(Wording.talk(seconds)) of the call \(seconds < 120 ? "has" : "have") no name yet"
        case .fixes(let fixes) where fixes.allSatisfy({ $0.from == .others && $0.sure == true }):
            "\(fixes.count) \(fixes.count == 1 ? "line" : "lines") nobody claimed: \(desk.reviewProvider.name) is sure who said \(fixes.count == 1 ? "it" : "them")"
        case .fixes(let fixes) where fixes.allSatisfy({ $0.from == .others }):
            "\(fixes.count) \(fixes.count == 1 ? "line" : "lines") nobody claimed \(fixes.count == 1 ? "has" : "have") a likely name"
        case .fixes(let fixes): "\(fixes.count) \(fixes.count == 1 ? "line" : "lines") may be under the wrong name"
        }
    }

    private var detail: String? {
        switch question.kind {
        case .wasYou: return "It sounds like your own voice, coming back through your speakers."
        case .who(let speaker, _):
            return "AnyRec hasn't heard this person before. They spoke for \(Wording.talk(speakers.row(for: speaker)?.talkTime ?? 0))."
        case .confirm(let speaker, _):
            return "Someone new. \(Wording.shortApp(app)) showed this name while they talked, about \(Wording.talk(speakers.row(for: speaker)?.talkTime ?? 0)) in total."
        case .samePerson: return "They sound alike, so AnyRec may have heard one person as two."
        case .sort: return "They talked right after each other, so AnyRec may have mixed them up. It has guessed each line. Change the ones that are wrong."
        case .eachLine(_, let lines, _, let several):
            let count = lines.count == 1 ? "this line" : "these \(lines.count) lines"
            return several
                ? "AnyRec heard \(count) as one person, but \(Wording.shortApp(app)) showed different people talking. Say who said each one. Any you leave stay as they are."
                : "AnyRec couldn't tell who said \(count). Say who said each one, or leave them as they are."
        case .unnamedBits(let lines, _, let onlyOther):
            let words = lines.prefix(2).compactMap { speakers.lines.indices.contains($0) ? "“\(speakers.lines[$0].text)”" : nil }
            return onlyOther != nil
                ? "Things like \(words.joined(separator: " and ")). Leaving them is fine."
                : "Things like \(words.joined(separator: " and ")), too short to tell apart by voice. \(desk.reviewProvider.name) can read the conversation around each and suggest who said it. Leaving them is fine."
        case .fixes(let fixes) where fixes.allSatisfy({ $0.from == .others && $0.sure == true }):
            return "Mostly words cut off the end or start of someone's sentence. Look through a few, then assign them all."
        case .fixes(let fixes) where fixes.allSatisfy({ $0.from == .others }):
            return "\(desk.reviewProvider.name)'s best reading of the conversation, but someone else could have said them. Check each one."
        case .fixes: return "AnyRec read the conversation again and thinks these belong to someone else."
        }
    }

    private var badge: String {
        switch question.kind {
        case .samePerson, .sort: "2"
        case .fixes(let fixes): "\(fixes.count)"
        case .eachLine(_, let lines, _, _): "\(lines.count)"
        case .wasYou: "Me"
        case .confirm(_, let name):
            String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
        default: "?"
        }
    }

    private var badgeColour: Color {
        switch question.kind {
        case .wasYou: SpeakerColour.of(.me)
        case .confirm(let speaker, _), .sort(let speaker, _, _, _): SpeakerColour.of(speaker)
        default: .gray
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch question.kind {
        case .wasYou(let speaker), .who(let speaker, _), .confirm(let speaker, _):
            ClipList(clips: speakers.row(for: speaker)?.clips ?? [], speakers: speakers, playback: playback,
                     notThem: NotThem(label: notLabel, speaker: speaker, desk: desk, done: done))
        case .samePerson(let a, let b):
            HStack(alignment: .top, spacing: 8) {
                ForEach([a, b], id: \.self) { speaker in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name(speaker)).font(.callout.bold())
                        ClipList(clips: Array((speakers.row(for: speaker)?.clips ?? []).prefix(1)), speakers: speakers, playback: playback,
                                 notThem: NotThem(label: "Not \(Wording.firstName(name(speaker)))?", speaker: speaker, desk: desk, done: done))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .sort(let speaker, let candidates, let lines, let guesses):
            SortLineChoices(desk: desk, speakers: speakers, playback: playback, source: speaker,
                            candidates: candidates, lines: lines, guesses: guesses, picks: $picks)
        case .eachLine(let speaker, let lines, let guesses, _):
            let left = lines.filter { !answeredLines.contains($0) }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(allLines ? left : Array(left.prefix(6)), id: \.self) { line in
                    EachLineRow(line: line, guess: guesses[line], speaker: speaker, desk: desk, speakers: speakers,
                                playback: playback, names: names) { choice in
                        answeredLines.insert(line)
                        desk.assignLines([line], to: choice)
                        done("That line is now \(PersonPicker.describe(choice, in: speakers, names: names))'s.")
                    }
                }
                if left.count > 6, !allLines {
                    Button("Show All \(left.count)") { allLines = true }.buttonStyle(.link).controlSize(.small)
                }
            }
        case .unnamedBits(let lines, let seconds, _):
            if seconds >= 60 {
                VStack(spacing: 4) {
                    ForEach(lines.prefix(4), id: \.self) { line in LineClip(line: line, speakers: speakers, playback: playback) }
                }
            }
        case .fixes(let fixes):
            correctionList(fixes)
        }
    }

    private func correctionList(_ fixes: [SpeakerCorrection]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(fixes.prefix(shownFixes), id: \.line) { fix in
                CorrectionRow(fix: fix, desk: desk, speakers: speakers, playback: playback, names: names, done: done)
                    .padding(.vertical, 6)
                Divider()
            }
            /// Ten more at a time: a hundred rows of buttons laid out at once slowed the page.
            if fixes.count > shownFixes {
                Button("Show \(min(10, fixes.count - shownFixes)) More") { shownFixes += 10 }
                    .buttonStyle(.link).controlSize(.small).padding(.top, 4)
            }
        }
    }

    // MARK: Answers

    @ViewBuilder private var answers: some View {
        /// Wraps rather than truncates: the page's column narrows when the sidebar shows.
        AnswerFlow(spacing: 8) {
            switch question.kind {
            case .wasYou(let speaker):
                Button("Yes, That's Me") { desk.assign(speaker, to: .speaker(.me)); done("That was you.") }.buttonStyle(.borderedProminent)
                someoneElse(for: speaker, offersMe: false)
            case .who(let speaker, let candidates):
                ForEach(candidates, id: \.self) { candidate in
                    Button(candidate) { desk.assign(speaker, to: .name(candidate, person: nil)); done("\(name(speaker)) is \(candidate).") }
                }
                someoneElse(for: speaker, offersMe: true)
                Button("I Don't Know") { skip(question.id) }.buttonStyle(.link)
            case .confirm(let speaker, let candidate):
                Button("Yes, That's \(Wording.firstName(candidate))") { desk.confirm(speaker, as: candidate); done("\(candidate), confirmed.") }
                    .buttonStyle(.borderedProminent)
                someoneElse(for: speaker, offersMe: true, label: "No, someone else…")
            case .samePerson(let a, let b):
                Button("Yes, Same Person") { desk.assign(b, to: .speaker(a)); done("\(name(b)) is \(name(a)).") }.buttonStyle(.borderedProminent)
                Button("No, Two People") { skip(question.id) }
            case .sort(let speaker, let names, let lines, let guesses):
                Button("Done") {
                    let choices = lines.map { line in
                        (line, picks[line] ?? speakers.speaker(named: guesses[line] ?? names[0]))
                    }
                    desk.sort(speaker, picks: Dictionary(uniqueKeysWithValues: choices))
                    if desk.failure == nil { done("Sorted \(choices.count) lines.") }
                }
                .buttonStyle(.borderedProminent)
            case .unnamedBits(let lines, _, let onlyOther):
                unclaimedAnswers(lines, onlyOther: onlyOther)
            case .fixes(let fixes):
                let sure = fixes.allSatisfy { $0.from == .others && $0.sure == true }
                Button(sure ? "Assign All \(fixes.count)" : "Fix All \(fixes.count)") {
                    desk.acceptAll(fixes)
                    done(sure ? "Assigned \(fixes.count) lines." : "Fixed \(fixes.count) lines.")
                }
                .buttonStyle(.borderedProminent)
            case .eachLine(_, let lines, let guesses, _):
                guessAnswers(lines, guesses: guesses)
            }
            if case .unnamedBits = question.kind {
                Button("Leave Them") { skip(question.id) }.buttonStyle(.link)
            } else {
                Button("Skip") { skip(question.id) }.buttonStyle(.link)
            }
        }
        .controlSize(.regular)
    }

    @ViewBuilder private func unclaimedAnswers(_ lines: [Int], onlyOther: Speaker?) -> some View {
        if let onlyOther {
            Button("They're All \(Wording.firstName(name(onlyOther)))") {
                desk.assignLines(lines, to: .speaker(onlyOther)); done("All of them are \(name(onlyOther))'s now.")
            }
            .buttonStyle(.borderedProminent)
            SomeoneElseButton(desk: desk, title: "Who said these lines?") { choice in
                desk.assignLines(lines, to: choice)
                if desk.failure == nil { done("Assigned \(lines.count) lines.") }
            }
            Button("Let Me Listen") { listen(); skip(question.id) }
        } else {
            Button("Ask \(desk.reviewProvider.name) Who Said These") {
                Task { if let text = await desk.askAboutUnclaimed() { asked(text) } }
            }
            .buttonStyle(.borderedProminent)
            .disabled(desk.asking)
            .help("Sends these lines, the lines around them and who the call showed talking to \(desk.reviewProvider.company). Nothing is assigned until you say so.")
            if desk.asking { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private func guessAnswers(_ lines: [Int], guesses: [Int: String]) -> some View {
        let guessed = lines.filter { !answeredLines.contains($0) && guesses[$0] != nil }
        if guessed.count > 1 {
            Button("Use \(Wording.shortApp(app))'s \(guessed.count) Guesses") {
                answeredLines.formUnion(guessed)
                desk.assignGuesses(Dictionary(uniqueKeysWithValues: guessed.map { ($0, guesses[$0]!) }))
                done("\(guessed.count) lines now have the name \(Wording.shortApp(app)) showed.")
            }
        }
    }

    private func someoneElse(for speaker: Speaker, offersMe: Bool, label: String = "Someone else…") -> some View {
        SomeoneElseButton(desk: desk, title: "Who is this?", exclude: speaker, offersMe: offersMe, label: label) { choice in
            desk.assign(speaker, to: choice)
            if desk.failure == nil { done("\(name(speaker)) is \(PersonPicker.describe(choice, in: speakers, names: names)).") }
        }
    }
}
