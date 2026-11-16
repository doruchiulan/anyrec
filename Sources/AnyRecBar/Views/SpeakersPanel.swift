import AnyRecKit
import SwiftUI

/// The recording page's speakers as the Kit reads them, and the changes the panel and the
/// transcript's labels make. Read off the main thread — it loads the voice library — when
/// the recording or its transcript changes, never from a view's body.
@MainActor
@Observable
final class SpeakerDesk {
    let directory: URL
    private let controller: RecordingController
    private(set) var speakers: RecordingSpeakers?
    var failure: String?

    init(directory: URL, controller: RecordingController) {
        self.directory = directory
        self.controller = controller
    }

    func load() async {
        let directory = directory
        speakers = await Task.detached(priority: .userInitiated) { RecordingSpeakers.read(in: directory) }.value
    }

    var busy: Bool { controller.working.contains(directory) }

    /// A whole voice gets a name; its print is filed under it, or under the library person
    /// the name was picked or typed as. Me gives every line of it to Me instead, and
    /// remembers the owner only when that was ticked.
    func name(_ speaker: Speaker, _ chosen: ChosenName) {
        perform {
            if chosen.me {
                return try SpeakerEditing.giveToMe(speaker, in: directory, remember: chosen.rememberOwner)
            }
            return try SpeakerEditing.name(speaker, chosen.name, in: directory, learnCallName: chosen.learnCallName, person: chosen.person)
        }
    }

    /// What choosing a name means for each kind of row: Me is who you are (the recording calls
    /// you by it and the library remembers you); Call lines go to that person; a voice is
    /// named, as before.
    func choose(_ speaker: Speaker, _ chosen: ChosenName) {
        switch speaker {
        case .me:
            perform { try SpeakerEditing.nameMe(chosen.name, person: chosen.person, in: directory) }
        case .others:
            guard let speakers else { return }
            let lines = speakers.lineIndexes(of: .others)
            let target = chosen.me ? Speaker.me : speakers.speaker(named: chosen.name)
            perform { try SpeakerEditing.reassign(lines, to: target, in: directory) }
        default:
            name(speaker, chosen)
        }
    }

    /// Lines go to another speaker, in the speakers layer only.
    func reassign(_ lines: [Int], to speaker: Speaker) {
        perform { try SpeakerEditing.reassign(lines, to: speaker, in: directory) }
    }

    /// Every line of a speaker goes to Me, Call or another speaker. What naming the voice
    /// filed in the library is taken back; given to Me, its print joins the owner's.
    func give(_ speaker: Speaker, to target: Speaker) {
        perform { try SpeakerEditing.give(speaker, to: target, in: directory) }
    }

    func accept(_ correction: SpeakerCorrection) {
        perform { try TranscriptSpeakerReview.apply(correction, in: directory) }
    }

    func keep(_ correction: SpeakerCorrection) {
        perform { try TranscriptSpeakerReview.dismiss(correction, in: directory) }
    }

    /// Each change is one small file and a re-render, so it runs here and then the library
    /// is re-read: the entry's revision moves and the page reloads what it shows.
    private func perform(_ change: () throws -> [URL]) {
        guard !busy else { return }
        do {
            _ = try change()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        controller.reloadPeople()
        Task {
            await controller.reloadLibrary()
            await load()
        }
    }
}

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

/// Every speaker in the transcript, those that want a look first: how each was named, how
/// long they talked, clips that play only them, names worth choosing, and the lines the
/// review thinks are someone else's. Then the Call lines nobody claims, and who the call
/// window showed. Replaces the naming card, the corrections card and the roster.
struct SpeakersPanel: View {
    let desk: SpeakerDesk
    let speakers: RecordingSpeakers
    let playback: Playback
    let observed: CallParticipants?
    let voices: RecordingVoices?
    let duration: TimeInterval

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(speakers.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    SpeakerRowView(desk: desk, speakers: speakers, row: row, playback: playback)
                }
                if let failure = desk.failure { Notice(failure, level: .error) }
                if let observed, !observed.roster.isEmpty {
                    Divider()
                    ObservedParticipants(participants: observed, voices: voices, duration: duration)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .disabled(desk.busy)
        } label: {
            Text(Wording.speakersTitle(toCheck: speakers.needsChecking)).font(.headline)
        }
    }
}

private struct SpeakerRowView: View {
    let desk: SpeakerDesk
    let speakers: RecordingSpeakers
    let row: RecordingSpeakers.Row
    let playback: Playback
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(SpeakerColour.of(row.speaker)).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(row.label).font(.headline)
                Text(Wording.basis(of: row)).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(Wording.talkTime(row.talkTime, lines: row.lineCount))
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ClipButtons(clips: row.clips, playback: playback)
                Spacer()
                if row.choosable, !row.needsAttention {
                    Button(expanded ? "Done" : "Change…") { expanded.toggle() }
                        .controlSize(.small)
                }
            }
            if row.fusedNames.count > 1 {
                Text(Wording.fused(row.fusedNames)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if row.choosable, row.needsAttention || expanded {
                /// The choices belong to this row: inset under it, so "Or give every line of …"
                /// cannot read as the next speaker.
                VStack(alignment: .leading, spacing: 8) {
                    if let prompt = Wording.choicePrompt(for: row) {
                        Text(prompt).font(.caption).foregroundStyle(.secondary)
                    }
                    SpeakerChooser(speakers: speakers, speaker: row.speaker, candidates: row.candidates) { chosen in
                        desk.choose(row.speaker, chosen)
                        expanded = false
                    }
                    if row.speaker != .me {
                        GiveToChoices(speakers: speakers, speaker: row.speaker, wholeVoice: true, divided: false) { target in
                            desk.give(row.speaker, to: target)
                            expanded = false
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(row.corrections) { correction in
                CorrectionRow(desk: desk, speakers: speakers, correction: correction, playback: playback)
            }
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

/// A name chosen for a speaker: what the transcript shows, whether the call window's name for
/// the voice may be learned as its alias (only for a typed name, or the call window's own),
/// and the saved name of the library person it was picked or typed as, if any.
struct ChosenName {
    let name: String
    let learnCallName: Bool
    var person: String?
    /// Me: the lines go to Me, and no name is filed.
    var me = false
    /// Who to remember as the owner, when Me was chosen with the tick beside it on.
    var rememberOwner: OwnerToRemember?
}

/// Names to choose from, each with why, and a field for anyone else that completes from
/// everyone already named. The completions are the Kit's (`RecordingSpeakers.completions`),
/// worked out from the library the desk already read, and only when the text changes.
struct SpeakerChooser: View {
    let speakers: RecordingSpeakers
    let speaker: Speaker
    let candidates: [SpeakerCandidate]
    /// Whether Me may also remember the owner: only when it gives a whole voice to Me.
    var offersRemember = true
    let choose: (ChosenName) -> Void
    @State private var typing = false
    @State private var typed = ""
    @State private var suggestions: [PersonSuggestion] = []
    /// On by default, and nothing is remembered unless it is on when Me is pressed.
    @State private var rememberOwner = true
    @FocusState private var focused: Bool

    var body: some View {
        let remember = offersRemember ? speakers.row(for: speaker)?.rememberOwner : nil
        VStack(alignment: .leading, spacing: 6) {
            ForEach(candidates) { candidate in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button(Wording.candidate(candidate)) {
                        if candidate.isMe {
                            choose(ChosenName(name: candidate.name, learnCallName: false, me: true,
                                              rememberOwner: rememberOwner ? remember : nil))
                        } else {
                            choose(ChosenName(name: candidate.name, learnCallName: candidate.reason == .callWindow))
                        }
                    }
                    .controlSize(.small)
                    Text(Wording.candidateReason(candidate.reason)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if candidate.isMe, let remember {
                    Toggle(Wording.rememberOwner(remember), isOn: $rememberOwner)
                        .toggleStyle(.checkbox).controlSize(.small)
                        .help(Wording.rememberOwnerHelp(remember))
                }
            }
            if typing {
                HStack {
                    TextField("Name", text: $typed).textFieldStyle(.roundedBorder).controlSize(.small)
                        .focused($focused)
                        .textInputSuggestions(suggestions) { suggestion in
                            Text(Wording.completion(suggestion)).textInputCompletion(suggestion.shownName)
                        }
                        .onSubmit(save)
                        .onChange(of: typed, initial: true) { _, text in
                            suggestions = speakers.completions(for: speaker, typing: text)
                        }
                        .onAppear { focused = true }
                    Button("Save", action: save).controlSize(.small)
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button("Someone else…") { typing = true }.buttonStyle(.link).controlSize(.small)
            }
        }
    }

    /// A name that is exactly someone's (a picked completion fills in their shown name) is
    /// filed under that person, spelled as the library spells it; anything else is a new
    /// person, as typed.
    private func save() {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let person = speakers.person(for: speaker, typed: name) {
            choose(ChosenName(name: person.matched, learnCallName: true, person: person.savedName))
        } else if let picked = suggestions.first(where: { $0.shownName == name }) {
            /// Two people shown under one name: the first of them the list offered.
            choose(ChosenName(name: picked.shownName, learnCallName: true, person: picked.savedName))
        } else {
            choose(ChosenName(name: name, learnCallName: true))
        }
        typed = ""
        typing = false
    }
}

/// One line the review thinks is someone else's: what was said, why, a clip of it, and the
/// choice.
private struct CorrectionRow: View {
    let desk: SpeakerDesk
    let speakers: RecordingSpeakers
    let correction: SpeakerCorrection
    let playback: Playback

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if speakers.lines.indices.contains(correction.line) {
                let line = speakers.lines[correction.line]
                Text(line.text).font(.callout).textSelection(.enabled).lineLimit(4)
                Text(correction.reason).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ClipButtons(clips: [SpeakerClip.of(line, index: correction.line)], playback: playback)
                    Button(Wording.moveTo(speakers.label(correction.to))) { desk.accept(correction) }
                        .controlSize(.small)
                    Button("Keep") { desk.keep(correction) }.controlSize(.small)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// What a transcript line's speaker label opens: that speaker's clips and names, and the
/// choice of changing this line or every line of the voice. Giving a line to Me, Call or
/// another speaker moves that line only, or the whole voice when that is chosen.
struct LineSpeakerChooser: View {
    let desk: SpeakerDesk
    let line: Int
    let playback: Playback
    let done: () -> Void
    @State private var wholeVoice = false

    var body: some View {
        if let speakers = desk.speakers, speakers.lines.indices.contains(line) {
            let speaker = speakers.lines[line].speaker
            let row = speakers.row(for: speaker)
            let canNameVoice = row?.nameable == true
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(speakers.label(speaker)).font(.headline)
                    if let row { Text(Wording.basis(of: row)).font(.subheadline).foregroundStyle(.secondary) }
                }
                if let row, !row.clips.isEmpty { ClipButtons(clips: row.clips, playback: playback) }
                if canNameVoice {
                    Picker("Change", selection: $wholeVoice) {
                        Text(Wording.lineScope).tag(false)
                        Text(Wording.voiceScope).tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                SpeakerChooser(speakers: speakers, speaker: speaker, candidates: speakers.candidates(for: speaker),
                               offersRemember: wholeVoice && canNameVoice) { chosen in
                    if wholeVoice, canNameVoice {
                        desk.name(speaker, chosen)
                    } else {
                        desk.reassign([line], to: chosen.me ? .me : speakers.speaker(named: chosen.name))
                    }
                    done()
                }
                GiveToChoices(speakers: speakers, speaker: speaker, wholeVoice: wholeVoice && canNameVoice) { target in
                    if wholeVoice, canNameVoice {
                        desk.give(speaker, to: target)
                    } else {
                        desk.reassign([line], to: target)
                    }
                    done()
                }
            }
            .padding(14)
            .frame(width: 340, alignment: .leading)
            .disabled(desk.busy)
        } else {
            ProgressView().padding()
        }
    }

}

/// Me, Call and every other speaker in the recording, as small buttons that wrap, under
/// "Or give it to": what a transcript label's popover and a Speakers panel row both offer.
/// `wholeVoice` only changes the words; the caller decides what moves.
struct GiveToChoices: View {
    let speakers: RecordingSpeakers
    let speaker: Speaker
    let wholeVoice: Bool
    /// A divider above, where it follows the chooser in a popover. A panel row's inset box
    /// has its own edge.
    var divided = true
    let give: (Speaker) -> Void

    var body: some View {
        /// Me is left out where the names above already offer it (a speaker that is probably
        /// you), so there are never two Me buttons doing different things.
        let offersMe = speakers.candidates(for: speaker).contains(where: \.isMe)
        let others = ([Speaker.me, .others] + speakers.rows.map(\.speaker)).reduce(into: [Speaker]()) {
            if $1 != speaker, !$0.contains($1), !($1 == .me && offersMe) { $0.append($1) }
        }
        let label = wholeVoice ? speakers.label(speaker) : nil
        if !others.isEmpty {
            if divided { Divider() }
            Text(Wording.giveTo(voice: label)).font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(others, id: \.self) { target in
                    let targetLabel = speakers.label(target)
                    Button(targetLabel) { give(target) }.controlSize(.small).lineLimit(1)
                        .help(Wording.giveHelp(voice: label, to: target, targetLabel: targetLabel))
                }
            }
        }
    }
}


/// Buttons side by side at their own widths, wrapping onto a new row when the next one
/// does not fit. A grid of fixed columns left a column's width of space after a short
/// label like "Me".
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
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
            if needed > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
