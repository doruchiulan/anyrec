import Foundation

/// Someone the owner has already named, offered while a name is being typed for a voice:
/// the "Someone else…" field in the app and the terminal's prompt. Picking one names the
/// voice as that person, so its print joins theirs instead of starting a second record.
public struct PersonSuggestion: Equatable, Sendable, Identifiable {
    /// The library key the print is filed under.
    public let savedName: String
    /// What a transcript calls them (`VoiceLibrary.Person.shownName`).
    public let shownName: String
    /// Which of their names the typed text matched, as it is spelled in the library: the
    /// shown name, the saved name, an alias or the display name. The shown name when nothing
    /// was typed.
    public let matched: String
    /// The typed text is this name, ignoring case, diacritics and repeated spaces.
    public let exact: Bool

    public var id: String { savedName }

    public init(savedName: String, shownName: String, matched: String, exact: Bool) {
        self.savedName = savedName
        self.shownName = shownName
        self.matched = matched
        self.exact = exact
    }

    /// The matched name when it is not the one shown, for "Andrei Lungu — also Andi".
    public var alsoKnownAs: String? {
        PersonCompletion.fold(matched) == PersonCompletion.fold(shownName) ? nil : matched
    }
}

/// How typed text is matched against the people in the library. Pure: nothing here reads a
/// file, calls a model or leaves the machine.
public enum PersonCompletion {
    /// How many suggestions a list shows.
    public static let limit = 6

    /// Case, diacritics ("ș", "ş" and "s" alike; "ă" and "a") and runs of spaces ignored.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// How well `typed` (already folded) matches `name`: 0 the whole name, 1 the start of
    /// any of its words, 2 anywhere in it; nil not at all.
    static func rank(_ typed: String, in name: String) -> Int? {
        let name = fold(name)
        guard !typed.isEmpty, !name.isEmpty else { return nil }
        if name == typed { return 0 }
        if name.hasPrefix(typed) || name.contains(" " + typed) { return 1 }
        if name.contains(typed) { return 2 }
        return nil
    }

    /// People matching `typed`, best first: a whole name, then the start of a word, then
    /// anywhere, each tier by how close the person's voice is to `print`, then by name.
    /// Every name a person answers to is matched: shown, saved, aliases. `excluded` people
    /// are left out unless the text is exactly one of their names. With nothing typed, the
    /// people whose voices are nearest `print`, with no threshold; none without a print.
    public static func suggestions(
        _ typed: String, in library: VoiceLibrary, print: Voiceprint, limit: Int = limit,
        excluding excluded: (VoiceLibrary.Person) -> Bool = { _ in false }
    ) -> [PersonSuggestion] {
        let text = fold(typed)
        let closeness = { (person: VoiceLibrary.Person) -> Float in
            person.prints.map { VoiceLibrary.similarity($0, print) }.max() ?? -1
        }
        if text.isEmpty {
            guard !print.isEmpty else { return [] }
            return library.people
                .filter { !excluded($0) && !$0.prints.isEmpty }
                .map { ($0, closeness($0)) }
                .sorted { ($1.1, $0.0.shownName) < ($0.1, $1.0.shownName) }
                .prefix(limit)
                .map { PersonSuggestion(savedName: $0.0.name, shownName: $0.0.shownName, matched: $0.0.shownName, exact: false) }
        }
        let scored = library.people.compactMap { person -> (PersonSuggestion, Int, Float)? in
            /// The shown name first, so a tie reads as the name the transcript will show.
            var names = [person.shownName, person.name] + person.aliases
            if let display = person.displayName { names.append(display) }
            var best: (name: String, rank: Int)?
            for name in names {
                guard let rank = rank(text, in: name), rank < best?.rank ?? .max else { continue }
                best = (name, rank)
            }
            guard let best, best.rank == 0 || !excluded(person) else { return nil }
            let suggestion = PersonSuggestion(savedName: person.name, shownName: person.shownName,
                                              matched: best.name, exact: best.rank == 0)
            return (suggestion, best.rank, closeness(person))
        }
        return scored
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.2 != b.2 { return a.2 > b.2 }
                return a.0.shownName.localizedStandardCompare(b.0.shownName) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
    }
}

extension RecordingSpeakers {
    /// People to offer while a name is typed for `speaker`, best first. The owner (they are
    /// Me), people already named on another speaker here, and whoever this speaker already
    /// is are left out unless the text is exactly their name. With nothing typed, the saved
    /// voices nearest this one.
    public func completions(for speaker: Speaker, typing text: String, limit: Int = PersonCompletion.limit) -> [PersonSuggestion] {
        let taken = context.taken(besides: speaker)
        let current: String? = switch speaker {
        case .voice: voice(for: speaker)?.name
        case .named(let name): name
        default: nil
        }
        return PersonCompletion.suggestions(text, in: context.library, print: voice(for: speaker)?.print ?? [], limit: limit) { person in
            person.isOwner || context.isOwner(person.name) || context.isOwner(person.shownName)
                || taken.contains { person.answers(to: $0) || VoiceLibrary.normalized($0) == VoiceLibrary.normalized(person.shownName) }
                || current.map { person.answers(to: $0) || VoiceLibrary.normalized($0) == VoiceLibrary.normalized(person.shownName) } == true
        }
    }

    /// The one person `text` exactly names (ignoring case, diacritics and spacing), whoever
    /// they are; nil when nobody does, or more than one person does. A name typed and
    /// submitted is filed under this person rather than starting a new record.
    public func person(for speaker: Speaker, typed text: String) -> PersonSuggestion? {
        let exact = completions(for: speaker, typing: text, limit: .max).filter(\.exact)
        return exact.count == 1 ? exact[0] : nil
    }

    func voice(for speaker: Speaker) -> RecordingVoices.Voice? {
        guard case .voice(let letter) = speaker else { return nil }
        return context.voices?.voices.first { $0.letter == letter }
    }
}
