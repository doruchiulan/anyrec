import AnyRecKit
import SwiftUI

// MARK: - People

struct PersonListRow: View {
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
struct EachLineRow: View {
    let line: Int
    let guess: String?
    let speaker: Speaker
    let desk: SpeakerDesk
    let speakers: RecordingSpeakers
    let playback: Playback
    let names: [Speaker: String]
    let pick: (SpeakerDesk.PersonChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LineClip(line: line, speakers: speakers, playback: playback)
            HStack(spacing: 6) {
                if let guess {
                    Button(guess) { pick(.name(guess, person: nil)) }
                        .help("Who the call window showed talking during this line")
                }
                SomeoneElseButton(desk: desk, title: "Who said this?", exclude: speaker, pick: pick)
            }
            .controlSize(.small)
        }
    }
}

/// The bits nobody claimed, as one row: fine to leave, or give each to someone.
struct NotSureWhoRow: View {
    let desk: SpeakerDesk
    let speakers: RecordingSpeakers
    let playback: Playback
    let names: [Speaker: String]
    @Binding var open: Bool
    let done: (String) -> Void
    let showAll: () -> Void
    let asked: (String) -> Void
    let review: () -> Void

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
                        unclaimedLine(line, suggestion: suggested[line])
                    }
                    /// The rest in the transcript, filtered to them: laid out here, 175 rows of
                    /// buttons slowed the whole page.
                    if lines.count > 5 {
                        Button("Show All \(lines.count) in the Transcript") { showAll() }.buttonStyle(.link).controlSize(.small)
                    }
                    Text("These are too short to tell apart by voice. Leaving them is fine.").font(.caption).foregroundStyle(.secondary)
                    reviewActions(lines: lines, suggested: suggested)
                }
                .padding(.leading, 38).padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder private func reviewActions(lines: [Int], suggested: [Int: SpeakerCorrection]) -> some View {
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

    private func unclaimedLine(_ line: Int, suggestion: SpeakerCorrection?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LineClip(line: line, speakers: speakers, playback: playback)
            HStack(spacing: 6) {
                /// The model's answer first, where it gave one.
                if let suggestion {
                    Button(names[suggestion.to] ?? speakers.label(suggestion.to)) {
                        desk.accept(suggestion); done("That bit is \(names[suggestion.to] ?? speakers.label(suggestion.to))'s now.")
                    }
                    .buttonStyle(.borderedProminent)
                    .help(suggestion.reason)
                }
                ForEach(likely.filter { $0 != suggestion?.to }, id: \.self) { speaker in
                    Button(Wording.firstName(names[speaker] ?? speakers.label(speaker))) {
                        desk.assignLines([line], to: .speaker(speaker)); done("That bit is \(names[speaker] ?? speakers.label(speaker))'s now.")
                    }
                }
                SomeoneElseButton(desk: desk, title: "Who said this?") { choice in
                    if let suggestion { desk.accept(suggestion, as: choice) }
                    else { desk.assignLines([line], to: choice) }
                    if desk.failure == nil { done("Assigned to \(PersonPicker.describe(choice, in: speakers, names: names)).") }
                }
            }
            .controlSize(.small)
        }
    }

    /// The two people who talked most, as one-click answers.
    private var likely: [Speaker] {
        Array(speakers.rows.filter { $0.speaker != .me && $0.speaker != .others }.sorted { $0.talkTime > $1.talkTime }.prefix(2).map(\.speaker))
    }
}
