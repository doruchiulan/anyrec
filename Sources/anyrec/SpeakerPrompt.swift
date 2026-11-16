import Foundation
import AnyRecKit

/// Asking who each lettered voice is, in a plain terminal: one question per voice that
/// wants one, with clips of it as the clue and the names worth choosing numbered. Used
/// after a transcript and by `anyrec speakers`; the Kit works out the names and does the
/// naming, this only asks.
enum SpeakerPrompt {
    /// Nothing is asked when every voice has a name, or when nobody is at the keyboard.
    static func offer(_ voices: RecordingVoices?, in folder: URL) {
        guard voices != nil, Terminal.isInteractive, let speakers = RecordingSpeakers.read(in: folder) else { return }
        let asking = questions(speakers)
        guard !asking.isEmpty else { return }
        print("")
        print(
            "\(asking.count) \(asking.count == 1 ? "voice wants" : "voices want") "
                + "a name. Name them now and they are remembered for next time; "
                + "⏎ leaves one as it is.")
        let answers = ask(asking, in: speakers)
        guard !answers.isEmpty else { return }
        name(answers, in: folder)
    }

    /// The voices worth a question: unnamed, named against evidence that disagreed, or
    /// probably the person recording.
    static func questions(_ speakers: RecordingSpeakers) -> [RecordingSpeakers.Row] {
        speakers.rows.filter { $0.nameable && ($0.name == nil || $0.basis == .uncertain || $0.probablyYou) }
    }

    struct Answer: Equatable {
        let speaker: Speaker
        let name: String
        /// Whether the call window's name for the voice is this person's alias: typed
        /// names and the call window's own, never another candidate picked over it.
        let learnCallName: Bool
        /// The saved name of the library person this name was picked or typed as: the print
        /// is filed under them rather than under a new record.
        var person: String? = nil
        /// Every line of the voice goes to Me instead: it was the person recording. The
        /// terminal never remembers the owner; that takes the app's explicit tick.
        var me = false
    }

    /// What a typed reply comes to: an answer, or people already named who match it, to be
    /// offered as numbered choices before anything is committed.
    enum Reply: Equatable {
        case answer(Answer)
        case choose(typed: String, [PersonSuggestion])
    }

    static func ask(_ rows: [RecordingSpeakers.Row], in speakers: RecordingSpeakers) -> [Answer] {
        var answers: [Answer] = []
        for row in rows {
            print("")
            print(describe(row, in: speakers))
            print("  Who is this? (\(row.candidates.isEmpty ? "" : "a number, ")a name, or ⏎ to leave it) ", terminator: "")
            guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { continue }
            var reply = reply(line, for: row, in: speakers)
            while case .choose(let typed, let people) = reply {
                print(choices(typed: typed, people))
                print("  A number, another name, or ⏎ to use “\(typed)” ", terminator: "")
                reply = pick(readLine() ?? "", typed: typed, from: people, for: row, in: speakers)
            }
            if case .answer(let answer) = reply { answers.append(answer) }
        }
        return answers
    }

    /// A number picks a candidate. A name exactly one known person answers to is theirs,
    /// spelled as the library spells it; a name that matches people already named offers
    /// them first; anything else is a new name. Nil for a number with no candidate.
    static func reply(_ text: String, for row: RecordingSpeakers.Row, in speakers: RecordingSpeakers) -> Reply? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let number = Int(text) {
            guard row.candidates.indices.contains(number - 1) else { return nil }
            let candidate = row.candidates[number - 1]
            if candidate.isMe { return .answer(Answer(speaker: row.speaker, name: candidate.name, learnCallName: false, me: true)) }
            return .answer(Answer(speaker: row.speaker, name: candidate.name, learnCallName: candidate.reason == .callWindow))
        }
        if let person = speakers.person(for: row.speaker, typed: text) {
            return .answer(Answer(speaker: row.speaker, name: person.matched, learnCallName: true, person: person.savedName))
        }
        let people = speakers.completions(for: row.speaker, typing: text)
        guard people.isEmpty else { return .choose(typed: text, people) }
        return .answer(Answer(speaker: row.speaker, name: text, learnCallName: true))
    }

    /// The reply to the numbered people: a number picks one, ⏎ keeps what was typed as a new
    /// name, and other text is read as a fresh reply.
    static func pick(
        _ text: String, typed: String, from people: [PersonSuggestion], for row: RecordingSpeakers.Row,
        in speakers: RecordingSpeakers
    ) -> Reply? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .answer(Answer(speaker: row.speaker, name: typed, learnCallName: true)) }
        if let number = Int(text) {
            guard people.indices.contains(number - 1) else { return .choose(typed: typed, people) }
            let person = people[number - 1]
            return .answer(Answer(speaker: row.speaker, name: person.shownName, learnCallName: true, person: person.savedName))
        }
        return reply(text, for: row, in: speakers)
    }

    /// "1) Andrei Lungu (also Andi)", one per line.
    static func choices(typed: String, _ people: [PersonSuggestion]) -> String {
        (["    Already named, matching “\(typed)”:"] + people.enumerated().map { index, person in
            "    \(index + 1)) \(person.shownName)\(person.alsoKnownAs.map { " (also \($0))" } ?? "")"
        })
        .joined(separator: "\n")
    }

    /// One voice: who it is now and how that was decided, how long it talked, its clips
    /// with what was said in each, and the numbered names.
    static func describe(_ row: RecordingSpeakers.Row, in speakers: RecordingSpeakers) -> String {
        let how = row.probablyYou ? probablyYou(row.yourVoice) : basis(row.basis)
        var out = ["  \(row.label) — \(how), \(clock(row.talkTime)) over \(row.lineCount) \(row.lineCount == 1 ? "line" : "lines")"]
        for clip in row.clips where speakers.lines.indices.contains(clip.line) {
            out.append("    [\(clock(clip.start))–\(clock(clip.end))] \(excerpt(speakers.lines[clip.line].text))")
        }
        if row.fusedNames.count > 1 {
            out.append("    may be more than one person: the call window showed \(row.fusedNames.joined(separator: " and "))")
        }
        for (index, candidate) in row.candidates.enumerated() {
            let name = candidate.reason == .soundsLike ? "\(candidate.name)?" : candidate.name
            out.append("    \(index + 1)) \(name) — \(reason(candidate.reason))")
        }
        return out.joined(separator: "\n")
    }

    static func name(_ answers: [Answer], in folder: URL) {
        do {
            var written: [URL] = []
            for answer in answers {
                written = answer.me
                    ? try SpeakerEditing.giveToMe(answer.speaker, in: folder)
                    : try SpeakerEditing.name(
                        answer.speaker, answer.name, in: folder, learnCallName: answer.learnCallName, person: answer.person)
            }
            report(written, in: folder)
        } catch {
            print("  The names were not saved: \(error)")
        }
    }

    /// `--name A=John`: typed names, so a call window's name is learned as before.
    static func apply(_ names: [String: String], in folder: URL) {
        do {
            let (_, written) = try VoiceNaming.apply(names, in: folder)
            report(written, in: folder)
        } catch {
            print("  The names were not saved: \(error)")
        }
    }

    private static func report(_ written: [URL], in folder: URL) {
        print("")
        print(listing(in: folder))
        for url in written where url.pathExtension == "md" { print("  Wrote \(url.path)") }
        let library = VoiceLibrary.load()
        print("  Remembered: \(library.names.joined(separator: ", ")).")
    }

    /// Every speaker with how it was named and its first clip.
    static func listing(in folder: URL) -> String {
        guard let speakers = RecordingSpeakers.read(in: folder) else { return "" }
        return speakers.rows.filter(\.nameable).map { row in
            let letter: String? = if case .voice(let letter) = row.speaker, row.name != nil { letter } else { nil }
            var lines = ["  \(row.label)\(letter.map { " (Speaker \($0))" } ?? "") — \(basis(row.basis))"]
            if let clip = row.clips.first, speakers.lines.indices.contains(clip.line) {
                lines.append("    [\(clock(clip.start))] \(excerpt(speakers.lines[clip.line].text))")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    static func basis(_ basis: SpeakerBasis) -> String {
        switch basis {
        case .microphone: "your microphone"
        case .namedByYou: "named by you"
        case .review: "chosen by review"
        case .agreed: "call window and voice agree"
        case .voiceMatch: "voice match"
        case .callWindow: "call window"
        case .named: "named"
        case .uncertain: "uncertain"
        case .unnamed: "not named"
        }
    }

    /// "probably you: the call window showed you speaking".
    static func probablyYou(_ evidence: [YourVoiceEvidence]) -> String {
        "probably you: " + evidence.map { evidence in
            switch evidence {
            case .savedAsYou: "saved as you"
            case .yourCallName: "saved under your name in the call"
            case .shownSpeaking: "the call window showed you speaking"
            }
        }.joined(separator: "; ")
    }

    static func reason(_ reason: SpeakerCandidate.Reason) -> String {
        switch reason {
        case .yourVoice: "your voice; every line goes to Me"
        case .callWindow: "shown speaking in the call window"
        case .voiceMatch: "a saved voice matches"
        case .review: "chosen by review"
        case .introduced(let quote): "said “\(quote)”"
        case .onlyOneLeft: "the only one in the call without a voice"
        case .inCall: "in the call"
        case .windowTitle: "in the window title"
        case .soundsLike: "sounds like a saved voice"
        case .savedAsYou: "saved as you"
        case .yourCallName: "your name in the call window"
        }
    }

    static func excerpt(_ text: String, limit: Int = 90) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 3_600
            ? String(format: "%d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
