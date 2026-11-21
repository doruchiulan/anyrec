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
