import Foundation

/// The recording's people as the person recording thinks of them, and the plain questions
/// worth asking about them, one at a time. Built from `RecordingSpeakers`, so the terminal
/// and the app ask the same things; how a question is shown and answered is each
/// interface's. Nothing here says "voice", "speaker" or "Call": a question is about a
/// person, a few of their words, or bits nobody claimed.
extension RecordingSpeakers {
    /// How a person in the list stands, in the words the list shows.
    public enum PersonState: Equatable, Sendable {
        /// The microphone: the person recording.
        case you
        /// A saved voice matched, alone or with the call window.
        case recognised
        /// The owner named them and the library kept their voice.
        case rememberedNextTime
        /// The owner named them; their voice waits for one more call (`Admission.waiting`).
        case rememberedAfterAnotherCall
        /// Only the call window (or the review) gave the name; nothing is remembered yet.
        case newFromCallWindow
        /// No name.
        case unnamed
        /// Named for this recording; the library kept nothing (too short, mixed, sounds
        /// like someone else, or a name typed for lines).
        case namedForThisCall
    }

    public func state(of row: Row) -> PersonState {
        switch row.speaker {
        case .me: return .you
        case .others: return .unnamed
        default: break
        }
        if row.name == nil { return .unnamed }
        switch row.basis {
        case .agreed, .voiceMatch: return .recognised
        case .callWindow, .review: return .newFromCallWindow
        case .uncertain, .unnamed: return .unnamed
        case .microphone: return .you
        case .named: return .namedForThisCall
        case .namedByYou:
            switch row.kept {
            case .filed?, .confirmed?: return .rememberedNextTime
            case .waiting?: return .rememberedAfterAnotherCall
            case .tooShort?, .mixed?, .soundsLike?: return .namedForThisCall
            case nil:
                let known = row.name.flatMap { name in
                    context.library.people.first { $0.name == name } ?? context.library.person(answering: name)
                }
                return known?.prints.isEmpty == false ? .rememberedNextTime : .namedForThisCall
            }
        }
    }

    /// One thing to ask.
    public struct Question: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// A voice that sounds like the person recording.
            case wasYou(Speaker)
            /// A voice with no name: the people in the call it could be.
            case who(Speaker, candidates: [String])
            /// A name only the call window (or the review) gave.
            case confirm(Speaker, name: String)
            /// Two voices of one person.
            case samePerson(Speaker, Speaker)
            /// A voice the call window saw as several people: each of its lines, with the name
            /// it showed then, for an either-or sorting.
            case sort(Speaker, names: [String], lines: [Int], guesses: [Int: String])
            /// Lines nobody claimed; `onlyOther` when the call had one other person.
            case unnamedBits(lines: [Int], seconds: TimeInterval, onlyOther: Speaker?)
            /// Single lines the review thinks are someone else's.
            case fixes([SpeakerCorrection])
        }

        public let kind: Kind
        public let id: String
    }

    /// What to ask, most useful first: whether a voice is you, who the unnamed people are
    /// (the longest talker first), names only the call window gave, voices that are one
    /// person or several, the bits nobody claimed, then the review's line fixes.
    public var questions: [Question] {
        var asked: [Question] = []
        let voices = rows.filter { $0.speaker != .me && $0.speaker != .others }
        for row in voices where row.probablyYou {
            asked.append(.init(kind: .wasYou(row.speaker), id: "you-\(row.id)"))
        }
        for row in voices.sorted(by: { $0.talkTime > $1.talkTime }) where !row.probablyYou {
            if row.fusedNames.count > 1 {
                let lines = lineIndexes(of: row.speaker)
                asked.append(.init(kind: .sort(row.speaker, names: row.fusedNames, lines: lines,
                                               guesses: guesses(lines, among: row.fusedNames)), id: "sort-\(row.id)"))
            } else if state(of: row) == .unnamed {
                asked.append(.init(kind: .who(row.speaker, candidates: whoCandidates(row)), id: "who-\(row.id)"))
            } else if state(of: row) == .newFromCallWindow, let name = row.name {
                asked.append(.init(kind: .confirm(row.speaker, name: name), id: "confirm-\(row.id)"))
            }
        }
        for (a, b) in samePeople { asked.append(.init(kind: .samePerson(a, b), id: "same-\(a)-\(b)")) }
        let unclaimed = lineIndexes(of: .others)
        if !unclaimed.isEmpty {
            asked.append(.init(kind: .unnamedBits(lines: unclaimed, seconds: unclaimedTime, onlyOther: onlyOther), id: "bits"))
        }
        let fixes = (rows.flatMap(\.corrections) + callCorrections).sorted { $0.line < $1.line }
        if !fixes.isEmpty { asked.append(.init(kind: .fixes(fixes), id: "fixes")) }
        return asked
    }

    /// Names worth a button for an unnamed voice: people the call showed who have nothing
    /// under their name yet, best first, at most three.
    func whoCandidates(_ row: Row) -> [String] {
        let wanted = row.candidates.filter {
            switch $0.reason {
            case .callWindow, .onlyOneLeft, .inCall, .introduced, .voiceMatch, .review, .windowTitle: true
            default: false
            }
        }
        var seen: Set<String> = []
        return wanted.map(\.name).filter { seen.insert(VoiceLibrary.normalized($0)).inserted }.prefix(3).map { $0 }
    }

    /// For each line, the one of `names` the call window showed alone for most of it.
    func guesses(_ lines: [Int], among names: [String]) -> [Int: String] {
        let spans = participants?.spans ?? []
        var guessed: [Int: String] = [:]
        for index in lines where self.lines.indices.contains(index) {
            let line = self.lines[index]
            var shown: [String: Double] = [:]
            for span in spans where span.names.count == 1 && names.contains(span.names[0]) {
                let overlap = min(line.end, span.end) - max(line.start, span.start)
                if overlap > 0 { shown[span.names[0], default: 0] += overlap }
            }
            guessed[index] = shown.max { $0.value < $1.value }?.key ?? names[0]
        }
        return guessed
    }

    /// Pairs of people in this recording who are probably one: voices whose prints are as
    /// alike as one person's (`duplicateFloor`), or two names the library knows as the same
    /// person ("Vova" and "Vladimir Tikhonov"). The one who talked more comes first.
    var samePeople: [(Speaker, Speaker)] {
        let voices = (context.voices?.voices ?? []).filter { voice in rows.contains { $0.speaker == .voice(voice.letter) } }
        var pairs: [(Speaker, Speaker)] = []
        func add(_ a: Speaker, _ b: Speaker) {
            guard !pairs.contains(where: { Set([$0.0, $0.1]) == Set([a, b]) }) else { return }
            let ta = row(for: a)?.talkTime ?? 0, tb = row(for: b)?.talkTime ?? 0
            pairs.append(ta >= tb ? (a, b) : (b, a))
        }
        for (i, a) in voices.enumerated() {
            for b in voices.dropFirst(i + 1) where VoiceLibrary.similarity(a.print, b.print) >= VoiceLibrary.duplicateFloor {
                add(.voice(a.letter), .voice(b.letter))
            }
        }
        let named = rows.filter { $0.speaker != .me && $0.speaker != .others && $0.name != nil }
        let person = { (name: String) in context.library.people.first { $0.name == name } ?? context.library.person(answering: name) }
        for (i, a) in named.enumerated() {
            for b in named.dropFirst(i + 1) {
                if let pa = a.name.flatMap(person), let pb = b.name.flatMap(person), pa.name == pb.name { add(a.speaker, b.speaker) }
            }
        }
        return pairs
    }

    /// The one other speaker, when the transcript has exactly one besides you and the call
    /// window, where it was read, listed nobody else.
    public var onlyOther: Speaker? {
        let others = rows.map(\.speaker).filter { $0 != .me && $0 != .others }
        guard others.count == 1 else { return nil }
        if let roster = participants?.roster, roster.count > 2 { return nil }
        return others[0]
    }

    /// People the call window listed who said nothing: no speaker carries their name and
    /// they are not the person recording.
    public var silentPeople: [String] {
        let carried = rows.compactMap(\.name)
        return (participants?.roster ?? []).map(\.name).filter { name in
            !context.isOwner(name) && !carried.contains { VoiceLibrary.normalized($0) == VoiceLibrary.normalized(name) }
                && !context.library.people.contains { person in person.answers(to: name) && carried.contains { person.answers(to: $0) } }
        }
    }
}
