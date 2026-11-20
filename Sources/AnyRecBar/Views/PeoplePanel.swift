import AnyRecKit
import SwiftUI

/// The recording page's "People in this call": the people who were there, and, when AnyRec
/// is unsure about someone, one plain question at a time that plays a few of their words
/// and is answered by picking a person. Nothing in it says voice, speaker or Call; whether
/// an answer renames someone or joins two of them is the desk's business, and whether the
/// library remembers a voice is the Kit's (`VoiceLibrary.consider`). Every answer can be
/// undone. The questions and each person's standing come from `RecordingSpeakers`.
struct PeoplePanel: View {
    let desk: SpeakerDesk
    let speakers: RecordingSpeakers
    let playback: Playback
    let app: String?
    /// Shows one speaker's lines in the inspector's transcript, where each can be given to someone.
    var showInTranscript: (Speaker) -> Void = { _ in }
    /// Questions skipped or answered "I don't know", until the recording is opened again.
    @State private var dismissed: Set<String> = []
    @State private var index = 0
    /// The question on screen, kept by id: answering a line moves who talked longest, which
    /// reorders the questions, and the card must not jump to another person mid-answer.
    @State private var currentID: String?
    @State private var toast: String?
    @State private var open: Speaker?
    @State private var showsBits = false

    private var questions: [RecordingSpeakers.Question] { speakers.questions.filter { !dismissed.contains($0.id) } }

    var body: some View {
        let questions = questions
        let position = position(in: questions)
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if questions.isEmpty {
                    Label("Everyone has a name. Nothing to check.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    QuestionCard(
                        question: questions[position], position: position,
                        count: questions.count, desk: desk, speakers: speakers, playback: playback, app: app,
                        names: names, done: answered, skip: skip, move: move, listen: { showsBits = true },
                        asked: { text in toast = text; showSuggestions() })
                        .id(questions[position].id)
                }
                if let toast {
                    HStack {
                        Label(toast, systemImage: "checkmark").font(.callout)
                        Spacer()
                        if desk.canUndo { Button("Undo") { desk.undo(); self.toast = nil }.controlSize(.small) }
                    }
                    .padding(8)
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                if let failure = desk.failure { Notice(failure, level: .error) }
                list
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .disabled(desk.busy)
        } label: {
            HStack {
                Text("People in this call").font(.headline)
                Spacer()
                Text(Wording.questions(questions.count)).font(.subheadline)
                    .foregroundStyle(questions.isEmpty ? Color.green : .secondary)
            }
        }
    }

    // MARK: The list

    private var people: [RecordingSpeakers.Row] {
        speakers.rows.filter { $0.speaker != .others }
            .sorted { ($0.speaker == .me ? 0 : 1, -$0.talkTime) < ($1.speaker == .me ? 0 : 1, -$1.talkTime) }
    }

    /// What each person is called here; unnamed voices are Person 1, 2… by how long they spoke.
    private var names: [Speaker: String] {
        var names: [Speaker: String] = [:]
        var unnamed = 0
        for row in people {
            if row.speaker == .me { names[.me] = row.name ?? "You"; continue }
            if let name = row.name { names[row.speaker] = name } else { unnamed += 1; names[row.speaker] = "Person \(unnamed)" }
        }
        names[.others] = "Not sure who"
        return names
    }

    /// People the questions ask about line by line, because the call window showed several.
    private var mixed: Set<Speaker> {
        Set(speakers.questions.compactMap { if case .eachLine(let speaker, _, _, true) = $0.kind { speaker } else { nil } })
    }

    @ViewBuilder private var list: some View {
        Text("Who spoke").font(.caption).foregroundStyle(.secondary)
        VStack(spacing: 0) {
            ForEach(Array(people.enumerated()), id: \.element.id) { position, row in
                if position > 0 { Divider() }
                PersonListRow(row: row, name: names[row.speaker] ?? row.label, state: speakers.state(of: row), app: app,
                              severalPeople: mixed.contains(row.speaker),
                              open: open == row.speaker, desk: desk, speakers: speakers, playback: playback,
                              toggle: { open = open == row.speaker ? nil : row.speaker }, done: answered)
            }
            let silent = speakers.silentPeople
            if !silent.isEmpty {
                Divider()
                HStack(spacing: 10) {
                    Avatar(text: "+\(silent.count)", colour: .gray)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(silent.count > 2 ? silent.prefix(2).joined(separator: ", ") + " and \(silent.count - 2) others" : silent.joined(separator: ", "))
                            .lineLimit(1)
                        Text("In the call, didn't speak").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6).opacity(0.7)
            }
            if !speakers.lineIndexes(of: .others).isEmpty {
                Divider()
                NotSureWhoRow(desk: desk, speakers: speakers, playback: playback, names: names,
                              open: $showsBits, done: answered, showAll: { showInTranscript(.others) },
                              asked: { text in toast = text; showSuggestions() },
                              review: showSuggestions)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        let named = people.filter { $0.speaker != .me }
        let recognised = named.filter { [.recognised, .rememberedNextTime].contains(speakers.state(of: $0)) }.map { names[$0.speaker] ?? $0.label }
        let notYet = named.filter { ![.recognised, .rememberedNextTime].contains(speakers.state(of: $0)) }.map { names[$0.speaker] ?? $0.label }
        if Wording.nextCall(recognised: recognised) != nil || Wording.notYet(notYet) != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let text = Wording.nextCall(recognised: recognised) { Label(text, systemImage: "checkmark").font(.caption) }
                if let text = Wording.notYet(notYet) { Text(text).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4])))
        }
    }

    // MARK: Answers

    private func answered(_ text: String) {
        toast = text
        open = nil
    }

    /// Puts the suggestions for the unclaimed lines on the card: the sure ones first. Called
    /// once the answers are in, from a closure made before they were, so the questions are
    /// looked up when the card is drawn (`position`), not here.
    private func showSuggestions() {
        currentID = "fixes-sure"
    }

    private func skip(_ id: String) {
        dismissed.insert(id)
        toast = nil
    }

    private func move(_ step: Int) {
        let questions = questions
        guard questions.count > 1 else { return }
        index = (position(in: questions) + step + questions.count) % questions.count
        currentID = questions[index].id
    }

    /// The question last shown while it is still asked; else whatever now sits where it was.
    private func position(in questions: [RecordingSpeakers.Question]) -> Int {
        if let currentID, let found = questions.firstIndex(where: { $0.id == currentID }) { return found }
        /// The sure suggestions all assigned, or none: the likely ones next.
        if currentID == "fixes-sure", let found = questions.firstIndex(where: { $0.id == "fixes-likely" }) { return found }
        return max(0, min(index, questions.count - 1))
    }
}

// MARK: - One question

private struct QuestionCard: View {
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
    @State private var picking = false
    @State private var picks: [Int: String] = [:]
    @State private var whyOpen: Set<Int> = []
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
        case .sort(_, let names, let lines, let guesses):
            VStack(spacing: 0) {
                ForEach(lines.prefix(12), id: \.self) { line in
                    if speakers.lines.indices.contains(line) {
                        HStack {
                            LineClip(line: line, speakers: speakers, playback: playback)
                            Picker("Who", selection: Binding(get: { picks[line] ?? guesses[line] ?? names[0] }, set: { picks[line] = $0 })) {
                                ForEach(names, id: \.self) { Text(Wording.firstName($0)).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
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
            VStack(alignment: .leading, spacing: 0) {
                ForEach(fixes.prefix(shownFixes), id: \.line) { fix in
                    VStack(alignment: .leading, spacing: 4) {
                        LineClip(line: fix.line, speakers: speakers, playback: playback)
                        HStack(spacing: 6) {
                            Text(name(fix.from)).strikethrough().foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            Text(name(fix.to)).bold()
                            Spacer()
                            Button("Why?") { if whyOpen.contains(fix.line) { whyOpen.remove(fix.line) } else { whyOpen.insert(fix.line) } }
                                .buttonStyle(.link).controlSize(.small)
                            Button("Leave") { desk.keep(fix); done("Left as it was.") }.controlSize(.small)
                            Button("Fix") { desk.accept(fix); done("That line is now \(name(fix.to))'s.") }.controlSize(.small)
                        }
                        .font(.callout)
                        if whyOpen.contains(fix.line) {
                            Text(fix.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
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
                someoneElse(for: speaker, offersMe: true, label: "No, Someone Else…")
            case .samePerson(let a, let b):
                Button("Yes, Same Person") { desk.assign(b, to: .speaker(a)); done("\(name(b)) is \(name(a)).") }.buttonStyle(.borderedProminent)
                Button("No, Two People") { skip(question.id) }
            case .sort(let speaker, let names, let lines, let guesses):
                Button("Done") {
                    var chosen: [Int: String] = [:]
                    for line in lines { chosen[line] = picks[line] ?? guesses[line] ?? names[0] }
                    desk.sort(speaker, picks: chosen)
                    done("Sorted between \(Wording.list(names.map(Wording.firstName))).")
                }
                .buttonStyle(.borderedProminent)
            case .unnamedBits(let lines, _, let onlyOther):
                if let onlyOther {
                    Button("They're All \(Wording.firstName(name(onlyOther)))") {
                        desk.assignLines(lines, to: .speaker(onlyOther)); done("All of them are \(name(onlyOther))'s now.")
                    }
                    .buttonStyle(.borderedProminent)
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
            case .fixes(let fixes):
                let sure = fixes.allSatisfy { $0.from == .others && $0.sure == true }
                Button(sure ? "Assign All \(fixes.count)" : "Fix All \(fixes.count)") {
                    desk.acceptAll(fixes)
                    done(sure ? "Assigned \(fixes.count) lines." : "Fixed \(fixes.count) lines.")
                }
                .buttonStyle(.borderedProminent)
            case .eachLine(_, let lines, let guesses, _):
                let guessed = lines.filter { !answeredLines.contains($0) && guesses[$0] != nil }
                if guessed.count > 1 {
                    Button("Use \(Wording.shortApp(app))'s \(guessed.count) Guesses") {
                        answeredLines.formUnion(guessed)
                        desk.assignGuesses(Dictionary(uniqueKeysWithValues: guessed.map { ($0, guesses[$0]!) }))
                        done("\(guessed.count) lines now have the name \(Wording.shortApp(app)) showed.")
                    }
                }
            }
            if case .unnamedBits = question.kind {
                Button("Leave Them") { skip(question.id) }.buttonStyle(.link)
            } else {
                Button("Skip") { skip(question.id) }.buttonStyle(.link)
            }
        }
        .controlSize(.regular)
    }

    private func someoneElse(for speaker: Speaker, offersMe: Bool, label: String = "Someone Else…") -> some View {
        Button(label) { picking = true }
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                PersonPicker(desk: desk, title: "Who is this?", current: nil, exclude: speaker, offersMe: offersMe) { choice in
                    picking = false
                    desk.assign(speaker, to: choice)
                    done("\(name(speaker)) is \(PersonPicker.describe(choice, in: speakers, names: names)).")
                }
            }
    }
}

// MARK: - People

private struct PersonListRow: View {
    let row: RecordingSpeakers.Row
    let name: String
    let state: RecordingSpeakers.PersonState
    let app: String?
    let severalPeople: Bool
    let open: Bool
    let desk: SpeakerDesk
    let speakers: RecordingSpeakers
    let playback: Playback
    let toggle: () -> Void
    let done: (String) -> Void
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Avatar(text: initials, colour: SpeakerColour.of(row.speaker))
                    VStack(alignment: .leading, spacing: 1) {
                        Group {
                            if row.speaker == .me { Text("You").bold() + Text(row.name.map { " · \($0)" } ?? "").foregroundStyle(.secondary) }
                            else { Text(name).bold() }
                        }
                        .lineLimit(1)
                        Text(subtitle).font(.caption).foregroundStyle(attention ? Color.orange : .secondary)
                    }
                    Spacer()
                    Text(Wording.talk(row.talkTime)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hide" : "Show what they said")
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    ClipList(clips: row.clips, speakers: speakers, playback: playback,
                             notThem: NotThem(label: row.speaker == .me ? "Not you?" : "Not \(Wording.firstName(name))?",
                                              speaker: row.speaker, desk: desk, done: done))
                    if let why = Wording.kept(row.kept) {
                        Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if row.speaker == .me {
                        Text("Everything your microphone heard while the call could hear you. Who you are is set in People.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(state == .unnamed ? "Who Is This?" : "Not \(Wording.firstName(name))?") { picking = true }
                            .popover(isPresented: $picking, arrowEdge: .bottom) {
                                PersonPicker(desk: desk, title: "Who is it, then?", current: nil, exclude: row.speaker, offersMe: true) { choice in
                                    picking = false
                                    desk.assign(row.speaker, to: choice)
                                    done("That was \(PersonPicker.describe(choice, in: speakers, names: [:])), not \(name).")
                                }
                            }
                    }
                }
                .padding(.leading, 38).padding(.bottom, 8)
            }
        }
    }

    private var subtitle: String {
        row.fusedNames.count > 1 || severalPeople ? "May be more than one person" : Wording.personState(state, app: app)
    }

    private var attention: Bool { state == .unnamed || state == .newFromCallWindow || row.fusedNames.count > 1 || severalPeople }

    private var initials: String {
        if row.speaker == .me { return "Me" }
        if state == .unnamed { return "?" }
        let words = Wording.firstName(name) == name ? name.split(separator: " ") : [Substring(Wording.firstName(name))]
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// One line of a person heard as several: its words, who the call window showed during it,
/// and anyone else. The answer moves that line only.
private struct EachLineRow: View {
    let line: Int
    let guess: String?
    let speaker: Speaker
    let desk: SpeakerDesk
    let speakers: RecordingSpeakers
    let playback: Playback
    let names: [Speaker: String]
    let pick: (SpeakerDesk.PersonChoice) -> Void
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LineClip(line: line, speakers: speakers, playback: playback)
            HStack(spacing: 6) {
                if let guess {
                    Button(guess) { pick(.name(guess, person: nil)) }
                        .help("Who the call window showed talking during this line")
                }
                Button("Someone Else…") { picking = true }
                    .popover(isPresented: $picking, arrowEdge: .bottom) {
                        PersonPicker(desk: desk, title: "Who said this?", current: nil, exclude: speaker, offersMe: true) { choice in
                            picking = false
                            pick(choice)
                        }
                    }
            }
            .controlSize(.small)
        }
    }
}

/// The bits nobody claimed, as one row: fine to leave, or give each to someone.
private struct NotSureWhoRow: View {
    let desk: SpeakerDesk
    let speakers: RecordingSpeakers
    let playback: Playback
    let names: [Speaker: String]
    @Binding var open: Bool
    let done: (String) -> Void
    let showAll: () -> Void
    let asked: (String) -> Void
    let review: () -> Void
    @State private var picking: Int?

    var body: some View {
        let lines = speakers.lineIndexes(of: .others)
        let suggested = Dictionary(speakers.callCorrections.map { ($0.line, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 10) {
                    Avatar(text: "?", colour: .gray)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Not sure who").bold()
                        Text(speakers.unclaimedTime < 60 ? "\(lines.count) short \(lines.count == 1 ? "bit" : "bits") · fine to leave" : "\(lines.count) moments without a name")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Wording.talk(speakers.unclaimedTime)).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines.prefix(5), id: \.self) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            LineClip(line: line, speakers: speakers, playback: playback)
                            HStack(spacing: 6) {
                                /// The model's answer first, where it gave one.
                                if let suggestion = suggested[line] {
                                    Button(names[suggestion.to] ?? speakers.label(suggestion.to)) {
                                        desk.accept(suggestion); done("That bit is \(names[suggestion.to] ?? speakers.label(suggestion.to))'s now.")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .help(suggestion.reason)
                                }
                                ForEach(likely.filter { $0 != suggested[line]?.to }, id: \.self) { speaker in
                                    Button(Wording.firstName(names[speaker] ?? speakers.label(speaker))) {
                                        desk.assignLines([line], to: .speaker(speaker)); done("That bit is \(names[speaker] ?? speakers.label(speaker))'s now.")
                                    }
                                }
                                Button("Someone Else…") { picking = line }
                                    .popover(isPresented: Binding(get: { picking == line }, set: { if !$0 { picking = nil } }), arrowEdge: .bottom) {
                                        PersonPicker(desk: desk, title: "Who said this?", current: nil, exclude: nil, offersMe: true) { choice in
                                            picking = nil
                                            desk.assignLines([line], to: choice)
                                            done("That bit is \(PersonPicker.describe(choice, in: speakers, names: names))'s now.")
                                        }
                                    }
                            }
                            .controlSize(.small)
                        }
                    }
                    /// The rest in the transcript, filtered to them: laid out here, 175 rows of
                    /// buttons slowed the whole page.
                    if lines.count > 5 {
                        Button("Show All \(lines.count) in the Transcript") { showAll() }.buttonStyle(.link).controlSize(.small)
                    }
                    Text("These are too short to tell apart by voice. Leaving them is fine.").font(.caption).foregroundStyle(.secondary)
                    if !suggested.isEmpty {
                        HStack(spacing: 8) {
                            Text("\(suggested.count) of these have a suggested name.").font(.caption)
                            Button("Review Suggestions") { review() }.buttonStyle(.link)
                        }
                        .controlSize(.small)
                    }
                    let unasked = lines.filter { suggested[$0] == nil && !speakers.askedAboutUnclaimed.contains($0) }.count
                    if unasked > 0 {
                    HStack(spacing: 8) {
                        Button(suggested.isEmpty ? "Ask \(desk.reviewProvider.name) Who Said These"
                                                 : "Ask \(desk.reviewProvider.name) About the Other \(unasked)") {
                            Task { if let text = await desk.askAboutUnclaimed() { asked(text) } }
                        }
                        .disabled(desk.asking)
                        .help("Sends these lines, the lines around them and who the call showed talking to \(desk.reviewProvider.company). Nothing is assigned until you say so.")
                        if desk.asking {
                            ProgressView().controlSize(.small)
                            Text("Reading the conversation…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .controlSize(.small)
                    }
                }
                .padding(.leading, 38).padding(.bottom, 8)
            }
        }
    }

    /// The two people who talked most, as one-click answers.
    private var likely: [Speaker] {
        Array(speakers.rows.filter { $0.speaker != .me && $0.speaker != .others }.sorted { $0.talkTime > $1.talkTime }.prefix(2).map(\.speaker))
    }
}

// MARK: - Pieces

/// A round badge: initials, "?" or a count, in the person's colour.
private struct Avatar: View {
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

/// What a sample offers when it may not be the person it is filed under: "Not Ciprian?"
/// moves that one line to whoever is picked, and the samples are picked again from the
/// person's other lines. The whole person is not touched.
private struct NotThem {
    let label: String
    let speaker: Speaker
    let desk: SpeakerDesk
    let done: (String) -> Void
}

/// A person's few seconds, each playable, with what was said.
private struct ClipList: View {
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
private struct LineClip: View {
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
private struct ClipLine: View {
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
private struct AnswerFlow: Layout {
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

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

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
