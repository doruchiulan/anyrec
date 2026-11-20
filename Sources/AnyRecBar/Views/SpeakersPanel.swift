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

    func accept(_ correction: SpeakerCorrection) {
        perform { try TranscriptSpeakerReview.apply(correction, in: directory) }
    }

    func keep(_ correction: SpeakerCorrection) {
        perform { try TranscriptSpeakerReview.dismiss(correction, in: directory) }
    }

    // MARK: People in this call

    /// Who an answer names: someone already speaking in this recording, or a name (a person
    /// the call window showed, one from the library, or someone new).
    enum PersonChoice: Equatable {
        case speaker(Speaker)
        case name(String, person: String?)
    }

    /// The answer to "who is this?" about a whole person. Someone already in this recording
    /// takes all of their lines (two rows become one); anyone else becomes their name, and
    /// the library keeps the voice when it safely can. Unclaimed bits are given line by line.
    func assign(_ speaker: Speaker, to choice: PersonChoice) {
        guard let speakers else { return }
        let lines = speakers.lineIndexes(of: speaker)
        switch (speaker, choice) {
        case (.others, .speaker(let target)): perform { try SpeakerEditing.reassign(lines, to: target, in: directory) }
        case (.others, .name(let name, _)): perform { try SpeakerEditing.reassign(lines, to: speakers.speaker(named: name), in: directory) }
        case (_, .speaker(let target)) where target == speaker: return
        case (_, .speaker(.me)): perform { try SpeakerEditing.giveToMe(speaker, in: directory) }
        case (_, .speaker(let target)): perform { try SpeakerEditing.give(speaker, to: target, in: directory) }
        case (_, .name(let name, let person)): perform { try SpeakerEditing.name(speaker, name, in: directory, person: person) }
        }
    }

    /// One line, or a few, to someone.
    func assignLines(_ lines: [Int], to choice: PersonChoice) {
        guard let speakers else { return }
        let target: Speaker = switch choice {
        case .speaker(let speaker): speaker
        case .name(let name, _): speakers.speaker(named: name)
        }
        perform { try SpeakerEditing.reassign(lines, to: target, in: directory) }
    }

    /// "Is this Madalin?" — yes: the owner's word on the name the call window gave, which is
    /// what lets the library keep the voice.
    func confirm(_ speaker: Speaker, as name: String) {
        perform { try SpeakerEditing.name(speaker, name, in: directory) }
    }

    /// A voice the call window saw as several people, sorted line by line: each line goes to
    /// the person picked for it; the voice keeps the most picked name, for this call only
    /// (a mixed voice is never remembered).
    func sort(_ speaker: Speaker, picks: [Int: String]) {
        guard let speakers, let main = Dictionary(grouping: picks.values, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key
        else { return }
        let elsewhere = Dictionary(grouping: picks.filter { $0.value != main }.keys, by: { picks[$0]! })
        perform {
            var written: [URL] = []
            for (name, lines) in elsewhere {
                written += try SpeakerEditing.reassign(lines.sorted(), to: speakers.speaker(named: name), in: directory)
            }
            written += try SpeakerEditing.name(speaker, main, in: directory)
            return written
        }
    }

    func acceptAll(_ corrections: [SpeakerCorrection]) {
        perform {
            var written: [URL] = []
            for correction in corrections { written += try TranscriptSpeakerReview.apply(correction, in: directory) }
            return written
        }
    }

    /// Every answer can be taken back: the transcript's selection and layers, and the voice
    /// library, as they were just before it.
    private struct Snapshot {
        let files: [URL: Data]
        let library: VoiceLibrary
    }
    private var history: [Snapshot] = []
    var canUndo: Bool { !history.isEmpty }

    private func snapshot() -> Snapshot {
        let layout = RecordingLayout(directory: directory)
        var files: [URL: Data] = [:]
        for url in [layout.selection] + layout.files(in: .transcripts) + [layout.directory.appendingPathComponent("Transcript.md")] {
            if let data = try? Data(contentsOf: url) { files[url] = data }
        }
        return Snapshot(files: files, library: VoiceLibrary.load())
    }

    func undo() {
        guard !busy, let last = history.popLast() else { return }
        let layout = RecordingLayout(directory: directory)
        for url in layout.files(in: .transcripts) where last.files[url] == nil { try? FileManager.default.removeItem(at: url) }
        for (url, data) in last.files { try? data.write(to: url, options: .atomic) }
        try? last.library.save()
        _ = try? TranscriptStore.render(in: directory)
        failure = nil
        controller.reloadPeople()
        Task {
            await controller.reloadLibrary()
            await load()
        }
    }

    /// Each change is one small file and a re-render, so it runs here and then the library
    /// is re-read: the entry's revision moves and the page reloads what it shows.
    private func perform(_ change: () throws -> [URL]) {
        guard !busy else { return }
        history.append(snapshot())
        if history.count > 20 { history.removeFirst() }
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
    let pick: (SpeakerDesk.PersonChoice) -> Void
    @State private var browsing = false
    @State private var query = ""
    @FocusState private var searching: Bool

    var body: some View {
        if let speakers = desk.speakers {
            VStack(alignment: .leading, spacing: 8) {
                if let title { Text(title).font(.headline) }
                if browsing { library(speakers) } else { inCall(speakers) }
            }
            .padding(12)
            .frame(width: 300, alignment: .leading)
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

    private func inCall(_ speakers: RecordingSpeakers) -> some View {
        let choices = speakers.lineChoices
        let people = choices.speakers.filter { $0 != .me && $0 != exclude }
        return VStack(alignment: .leading, spacing: 2) {
            Text("In this call").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
            if current == .others {
                PersonRow(name: "Not sure who", hint: nil, ticked: true) {}
            }
            ForEach(people, id: \.self) { speaker in
                PersonRow(name: speakers.label(speaker), hint: nil, ticked: speaker == current) { choose(.speaker(speaker)) }
            }
            ForEach(choices.callNames, id: \.self) { name in
                PersonRow(name: name, hint: nil, ticked: false) { choose(.name(name, person: nil)) }
            }
            if offersMe, exclude != .me {
                Divider().padding(.vertical, 4)
                PersonRow(name: "Me", hint: speakers.row(for: .me)?.name, ticked: current == .me) { choose(.speaker(.me)) }
            }
            Divider().padding(.vertical, 4)
            PersonRow(name: "Someone else…", hint: nil, ticked: false, chevron: true) {
                browsing = true
                searching = true
            }
        }
    }

    private func library(_ speakers: RecordingSpeakers) -> some View {
        let text = query.trimmingCharacters(in: .whitespaces)
        let all = speakers.lineChoices.library
        let shown = text.isEmpty ? all : speakers.completions(for: .others, typing: text, limit: .max)
        let exact = speakers.person(for: .others, typed: text)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { browsing = false; query = "" } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).accessibilityLabel("Back to the people in this call")
                TextField("Type a name", text: $query)
                    .textFieldStyle(.roundedBorder).controlSize(.small).focused($searching)
                    .onSubmit { if !text.isEmpty { choose(.name(exact?.shownName ?? text, person: exact?.savedName)) } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !shown.isEmpty {
                        Text("From earlier calls").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
                    }
                    ForEach(shown) { person in
                        PersonRow(name: person.shownName, hint: nil, ticked: false) { choose(.name(person.shownName, person: person.savedName)) }
                    }
                    if !text.isEmpty, exact == nil {
                        PersonRow(name: "New person “\(text)”", hint: nil, ticked: false) { choose(.name(text, person: nil)) }
                    }
                    if shown.isEmpty, text.isEmpty {
                        Text("Nobody else is known yet. Type a name to add someone.").font(.callout).foregroundStyle(.secondary).padding(6)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
    }

    private func choose(_ choice: SpeakerDesk.PersonChoice) {
        if case .speaker(let speaker) = choice, speaker == current { return }
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
