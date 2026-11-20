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
                    context.library.people.first { $0.name == name } ?? context.person(answering: name)
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
            /// An unnamed person's lines one at a time, with who the call window showed during
            /// each where it showed one person: when it showed different people
            /// (`severalPeople`); when they add up to less speech than the library keeps a
            /// voice from (`VoiceLibrary.minimumSeconds`), so naming them together would
            /// remember nothing and only risk the wrong name on all of them; or when none is
            /// clean enough to play. A group of thirteen short lines, once its lines the window
            /// had guesses for were answered, came back as "Who is this?" with nothing to hear.
            case eachLine(Speaker, lines: [Int], guesses: [Int: String], severalPeople: Bool)
            /// Lines nobody claimed: all of them when the call had one other person
            /// (`onlyOther`), to give them all to; otherwise only those never sent to the review's
            /// model, to ask it about. Leftovers on a call of several are never one person's.
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
            } else if state(of: row) == .unnamed, let several = severalPeople(row.speaker) {
                asked.append(.init(kind: .eachLine(row.speaker, lines: lineIndexes(of: row.speaker), guesses: several, severalPeople: true),
                                   id: "lines-\(row.id)"))
            } else if state(of: row) == .unnamed, row.talkTime < VoiceLibrary.minimumSeconds || row.clips.isEmpty {
                let lines = lineIndexes(of: row.speaker)
                asked.append(.init(kind: .eachLine(row.speaker, lines: lines, guesses: shownAlone(lines), severalPeople: false),
                                   id: "lines-\(row.id)"))
            } else if state(of: row) == .unnamed {
                asked.append(.init(kind: .who(row.speaker, candidates: whoCandidates(row)), id: "who-\(row.id)"))
            } else if state(of: row) == .newFromCallWindow, let name = row.name {
                asked.append(.init(kind: .confirm(row.speaker, name: name), id: "confirm-\(row.id)"))
            }
        }
        for (a, b) in samePeople { asked.append(.init(kind: .samePerson(a, b), id: "same-\(a)-\(b)")) }
        let unclaimed = lineIndexes(of: .others)
        if let onlyOther, !unclaimed.isEmpty {
            asked.append(.init(kind: .unnamedBits(lines: unclaimed, seconds: unclaimedTime, onlyOther: onlyOther), id: "bits"))
        } else {
            let suggested = Set(callCorrections.map(\.line))
            let unasked = unclaimed.filter { !suggested.contains($0) && !askedAboutUnclaimed.contains($0) }
            if !unasked.isEmpty {
                let seconds = unasked.reduce(0) { $0 + max(0, lines[$1].end - lines[$1].start) }
                asked.append(.init(kind: .unnamedBits(lines: unasked, seconds: seconds, onlyOther: nil), id: "bits"))
            }
        }
        /// Lines nobody claimed that the model was sure of are one group, assigned at once;
        /// the likely ones are checked one by one; the review's own fixes stay apart.
        /// The unclaimed lines' row carries the same corrections as `callCorrections`: counted
        /// once, or every one of them was listed twice.
        let fixes = (rows.filter { $0.speaker != .others }.flatMap(\.corrections) + callCorrections).sorted { $0.line < $1.line }
        let sure = fixes.filter { $0.from == .others && $0.sure == true }
        let likely = fixes.filter { $0.from == .others && $0.sure == false }
        let review = fixes.filter { $0.sure == nil }
        if !sure.isEmpty { asked.append(.init(kind: .fixes(sure), id: "fixes-sure")) }
        if !likely.isEmpty { asked.append(.init(kind: .fixes(likely), id: "fixes-likely")) }
        if !review.isEmpty { asked.append(.init(kind: .fixes(review), id: "fixes")) }
        return asked
    }

    /// Names worth a button for an unnamed voice: people the call showed who have nothing
    /// under their name yet, best first, at most three. Someone in the call the window never
    /// showed talking is not one: three such names, the first alphabetically, were offered
    /// for a voice they had nothing to do with.
    func whoCandidates(_ row: Row) -> [String] {
        let wanted = row.candidates.filter {
            switch $0.reason {
            case .inCall: context.talkers.contains($0.name)
            case .callWindow, .onlyOneLeft, .introduced, .voiceMatch, .review, .windowTitle: true
            default: false
            }
        }
        var seen: Set<String> = []
        return wanted.map(\.name).filter { seen.insert(VoiceLibrary.normalized($0)).inserted }.prefix(3).map { $0 }
    }

    /// Who the call window showed for each of a speaker's lines, when it showed different
    /// people: at least two of them each alone on at least a fifth of the lines it showed
    /// anyone on. Nil when it showed one person, or nobody: then the lines are asked about
    /// together. A short voice on a three-hour Teams call held thirteen lines of four or more
    /// different people, and "Who is this?" could only name all of them at once.
    public func severalPeople(_ speaker: Speaker) -> [Int: String]? {
        let guessed = shownAlone(lineIndexes(of: speaker))
        let counts = Dictionary(grouping: guessed.values, by: { $0 }).mapValues(\.count)
        let floor = max(1, Int((Double(guessed.count) * 0.2).rounded(.up)))
        return counts.values.filter { $0 >= floor }.count >= 2 ? guessed : nil
    }

    func shownAlone(_ lines: [Int]) -> [Int: String] {
        var guessed: [Int: String] = [:]
        for index in lines where self.lines.indices.contains(index) {
            if let name = shownAlone(self.lines[index]) { guessed[index] = name }
        }
        return guessed
    }

    /// The one person the call window showed speaking alone for at least half of a line, and
    /// for longer than everyone else together.
    func shownAlone(_ line: Utterance) -> String? {
        let length = line.end - line.start
        guard length > 0 else { return nil }
        var alone: [String: Double] = [:]
        var rest = 0.0
        for span in context.spans.near(line.start, line.end) {
            let overlap = min(line.end, span.end) - max(line.start, span.start)
            guard overlap > 0 else { continue }
            if span.names.count == 1 { alone[span.names[0], default: 0] += overlap } else { rest += overlap }
        }
        guard let top = alone.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
        let others = alone.values.reduce(rest, +) - top.value
        return top.value >= 0.5 * length && top.value > others ? top.key : nil
    }

    /// For each line, the one of `names` the call window showed alone for most of it.
    func guesses(_ lines: [Int], among names: [String]) -> [Int: String] {
        let spans = context.spans
        var guessed: [Int: String] = [:]
        for index in lines where self.lines.indices.contains(index) {
            let line = self.lines[index]
            var shown: [String: Double] = [:]
            for span in spans.near(line.start, line.end) where span.names.count == 1 && names.contains(span.names[0]) {
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
        let person = { (name: String) in context.library.people.first { $0.name == name } ?? context.person(answering: name) }
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
        if context.roster.count > 2 { return nil }
        return others[0]
    }

    /// People the call window listed who said nothing: no speaker carries their name and
    /// they are not the person recording.
    public var silentPeople: [String] {
        let carried = rows.compactMap(\.name)
        return context.roster.filter { name in
            !context.isOwner(name) && !carried.contains { VoiceLibrary.normalized($0) == VoiceLibrary.normalized(name) }
                && !context.library.people.contains { person in person.answers(to: name) && carried.contains { person.answers(to: $0) } }
        }
    }
}
