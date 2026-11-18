import Foundation

/// A stretch of one speaker's own speech, short enough to listen to: what the Speakers
/// panel and the terminal play instead of a voice's longest line, which ran on into the
/// next speaker and was the line most likely to hold two people.
public struct SpeakerClip: Equatable, Hashable, Sendable {
    /// The transcript line it was taken from.
    public let line: Int
    public let start: TimeInterval
    public let end: TimeInterval

    /// Lines shorter than this are not clipped: a second of "yeah" says nothing about a voice.
    public static let minimumLine: TimeInterval = 2
    /// The longest clip, centred in its line.
    public static let maximumLength: TimeInterval = 8

    public var length: TimeInterval { end - start }

    /// A clip of one line, centred and capped, whatever the line's length.
    public static func of(_ line: Utterance, index: Int) -> SpeakerClip {
        let length = max(0, min(line.end - line.start, maximumLength))
        let middle = (line.start + line.end) / 2
        return SpeakerClip(line: index, start: middle - length / 2, end: middle + length / 2)
    }

    /// Up to `limit` clips of `speaker`, from different parts of the call. A line
    /// qualifies when it is at least `minimumLine` long, no other speaker's line overlaps
    /// it, and no review correction is pending on it. The call is cut in `limit` equal
    /// parts and each part gives its longest qualifying line (up to the cap, so an 8 s
    /// line and a 30 s line are equally good, and the nearer the part's middle wins);
    /// a part with none is filled from the rest of the call, as far as possible from the
    /// clips already taken. Fewer clips when fewer lines qualify.
    public static func clips(
        of speaker: Speaker, in lines: [Utterance], excluding pending: Set<Int> = [], limit: Int = 3
    ) -> [SpeakerClip] {
        guard limit > 0 else { return [] }
        let qualifying = lines.indices.filter { index in
            let line = lines[index]
            return line.speaker == speaker && !pending.contains(index) && line.start.isFinite && line.end.isFinite
                && line.end - line.start >= minimumLine
                && !lines.contains { $0.speaker != speaker && $0.start < line.end && $0.end > line.start }
        }
        guard !qualifying.isEmpty else { return [] }
        let duration = max(lines.map(\.end).max() ?? 0, 1)
        let part = duration / Double(limit)
        let middle = { (index: Int) in (lines[index].start + lines[index].end) / 2 }
        let worth = { (index: Int) in min(lines[index].end - lines[index].start, maximumLength) }

        var chosen: [Int] = []
        for slot in 0..<limit {
            let low = Double(slot) * part, high = Double(slot + 1) * part, centre = (low + high) / 2
            let inPart = qualifying.filter { !chosen.contains($0) && middle($0) >= low && (middle($0) < high || slot == limit - 1) }
            if let best = inPart.max(by: { (worth($0), -abs(middle($0) - centre)) < (worth($1), -abs(middle($1) - centre)) }) {
                chosen.append(best)
            }
        }
        while chosen.count < limit {
            let rest = qualifying.filter { !chosen.contains($0) }
            guard let far = rest.max(by: { a, b in
                let da = chosen.map { abs(middle($0) - middle(a)) }.min() ?? 0
                let db = chosen.map { abs(middle($0) - middle(b)) }.min() ?? 0
                return (da, worth(a)) < (db, worth(b))
            }) else { break }
            chosen.append(far)
        }
        return chosen.sorted { lines[$0].start < lines[$1].start }.map { of(lines[$0], index: $0) }
    }
}

/// How a speaker came to be called what it is. Interfaces word it.
public enum SpeakerBasis: String, Equatable, Sendable {
    /// The microphone's own lines: measured, not identified.
    case microphone
    case namedByYou
    /// The review picked between competing names.
    case review
    /// The call window and a saved voice both said who this is.
    case agreed
    case voiceMatch
    case callWindow
    /// Named, but nothing kept says how: older transcripts, and names typed for one line.
    case named
    /// The evidence disagreed and no name was settled.
    case uncertain
    case unnamed
}

/// Why a voice is probably the person recording, read from the files on disk when the
/// speakers are shown, so it holds for transcripts written before the owner merge too.
public enum YourVoiceEvidence: String, Equatable, Sendable, CaseIterable {
    /// The voice's name, or the saved person its name or print belongs to, is the
    /// library's owner.
    case savedAsYou
    /// Its saved person answers to a name the call window showed for you: your own tile,
    /// or the person it showed speaking while your microphone was.
    case yourCallName
    /// The call window showed you speaking for most of the time this voice spoke.
    case shownSpeaking
}

/// A name worth offering for a voice, with why. Offered, never applied without a click.
public struct SpeakerCandidate: Equatable, Sendable, Identifiable {
    public enum Reason: Equatable, Sendable {
        /// The voice is probably the person recording: the candidate is Me, and choosing it
        /// gives every line of the voice to Me.
        case yourVoice([YourVoiceEvidence])
        /// The call window showed this person while the voice spoke.
        case callWindow
        /// A saved voice in the library matched.
        case voiceMatch
        /// The review chose this name between competing ones.
        case review
        /// The voice introduced itself by this name.
        case introduced(quote: String)
        /// Everyone else the call window listed already has a voice, and this one is left.
        case onlyOneLeft
        /// The call window listed this person.
        case inCall
        /// The Slack window's title names this person.
        case windowTitle
        /// A saved voice is close, but not close enough to claim the name.
        case soundsLike
        /// Who Me is: the library already knows this person as the one recording.
        case savedAsYou
        /// Who Me is: the call window labelled this name as the person recording, or showed it
        /// while the microphone's lines were said.
        case yourCallName
    }

    public let name: String
    public let reason: Reason
    public var id: String { isMe ? "\u{0}me" : VoiceLibrary.normalized(name) }

    /// Choosing it gives the voice to Me rather than naming it.
    public var isMe: Bool { if case .yourVoice = reason { true } else { false } }

    /// Me, offered for a voice that is probably the person recording.
    public static func me(_ evidence: [YourVoiceEvidence]) -> SpeakerCandidate {
        SpeakerCandidate(name: Speaker.me.label, reason: .yourVoice(evidence))
    }
}

/// A saved person the call window says is the person recording, who the library does not
/// know as its owner yet. Offered beside Me as an explicit choice; never set without one.
public struct OwnerToRemember: Equatable, Sendable {
    /// The saved name of the library person to mark as the owner.
    public let person: String
    /// What the transcript calls them.
    public let shownName: String
    /// The name the call window showed for the owner, filed as their alias.
    public let display: String?

    public init(person: String, shownName: String, display: String?) {
        self.person = person
        self.shownName = shownName
        self.display = display
    }
}

/// Every speaker in a recording's transcript, with what is needed to check and change who
/// they are: how each was named, how long they talked, a few clips of them, the names worth
/// offering, and the review's line corrections. One read for the app's Speakers panel and
/// its transcript's label popovers, and for the terminal's prompts.
public struct RecordingSpeakers: Sendable {
    public struct Row: Sendable, Identifiable {
        public let speaker: Speaker
        /// The name this speaker carries now; nil for a letter, and for Me.
        public let name: String?
        public let basis: SpeakerBasis
        public let talkTime: TimeInterval
        public let lineCount: Int
        public let clips: [SpeakerClip]
        public let candidates: [SpeakerCandidate]
        /// The review thinks these of the speaker's lines are someone else's.
        public let corrections: [SpeakerCorrection]
        /// The call window showed these people inside this one voice.
        public let fusedNames: [String]
        /// Whether the whole voice can be named: a lettered voice, or a name typed for lines.
        public let nameable: Bool
        /// Why this speaker is probably the person recording; empty when nothing says so.
        /// Such a row is offered Me first, and wants a look.
        public let yourVoice: [YourVoiceEvidence]
        /// Who to remember as the owner if this speaker is given to Me, when the call window
        /// says so and the library has no owner yet.
        public let rememberOwner: OwnerToRemember?

        public var id: Speaker { speaker }
        public var label: String { name ?? speaker.label }
        public var probablyYou: Bool { !yourVoice.isEmpty }

        /// Whether the panel offers a choice for this row: a voice or typed name to name, Me
        /// to say who you are, or Call lines no voice claims to give to someone. The terminal
        /// asks only about `nameable` rows.
        public var choosable: Bool { nameable || speaker == .me || speaker == .others }

        /// Nothing should be left as "Me", "Call" or a letter: each asks until it is somebody.
        public var needsAttention: Bool {
            (choosable && name == nil) || basis == .uncertain || fusedNames.count > 1 || !corrections.isEmpty || probablyYou
        }
    }

    public let rows: [Row]
    /// The transcript's lines as they read now, voices still lettered, in the order the
    /// speakers layer indexes them.
    public let lines: [Utterance]
    /// Lines still marked Call that no voice claims.
    public let unclaimedLines: Int
    public let unclaimedTime: TimeInterval
    /// Corrections the review proposed for Call lines.
    public let callCorrections: [SpeakerCorrection]
    /// Candidate names for a Call line: only the call window's roster and the window title
    /// can say anything about it.
    public let callCandidates: [SpeakerCandidate]
    public let participants: CallParticipants?
    public let duration: TimeInterval
    /// The library and the names taken, kept from the read so a name being typed completes
    /// against them without reading the library again.
    let context: CandidateContext

    public var needsChecking: Int { rows.filter(\.needsAttention).count }

    public func row(for speaker: Speaker) -> Row? { rows.first { $0.speaker == speaker } }

    /// What a speaker is called now: its name, or its label.
    public func label(_ speaker: Speaker) -> String { row(for: speaker)?.label ?? speaker.label }

    /// The speaker a name means here: whoever carries it now, else the name itself.
    public func speaker(named name: String) -> Speaker {
        let key = VoiceLibrary.normalized(name)
        return rows.first { $0.name.map(VoiceLibrary.normalized) == key }?.speaker ?? .named(name)
    }

    /// The lines a speaker has now, for giving a whole voice to someone else.
    public func lineIndexes(of speaker: Speaker) -> [Int] { lines.indices.filter { lines[$0].speaker == speaker } }

    /// Names worth offering for whatever speaker a line has.
    public func candidates(for speaker: Speaker) -> [SpeakerCandidate] {
        speaker == .others ? callCandidates : row(for: speaker)?.candidates ?? []
    }

    public static func read(in directory: URL, library: VoiceLibrary = VoiceLibrary.load()) -> RecordingSpeakers? {
        let directory = OutputPlan(directory: directory).directory
        guard let current = RecordingTranscript.read(in: directory) else { return nil }
        return build(lines: current.transcript.utterances, voices: current.voices,
                     suggestions: current.wording?.suggestions ?? current.legacyReview?.suggestions ?? [],
                     corrections: current.pendingSpeakerChanges,
                     participants: CallParticipants.read(in: directory), info: RecordingInfo.read(directory),
                     library: library)
    }

    static func build(
        lines: [Utterance], voices: RecordingVoices?, suggestions: [SpeakerSuggestion], corrections: [SpeakerCorrection],
        participants: CallParticipants?, info: RecordingInfo?, library: VoiceLibrary
    ) -> RecordingSpeakers {
        let pending = Set(corrections.map(\.line))
        let context = CandidateContext(lines: lines, voices: voices, participants: participants, info: info, library: library)

        /// Speakers with lines: a voice whose every line was given to someone else is gone.
        /// Call lines no voice claims are a row of their own, so they can be given to someone.
        var speakers: [Speaker] = []
        for line in lines where !speakers.contains(line.speaker) { speakers.append(line.speaker) }

        let rows = speakers.map { speaker -> Row in
            let own = lines.filter { $0.speaker == speaker }
            let voice: RecordingVoices.Voice? = if case .voice(let letter) = speaker { voices?.voices.first { $0.letter == letter } } else { nil }
            let name: String? = switch speaker {
            case .me: voices?.meName
            case .others: nil
            case .voice: voice?.name
            case .named(let name): name
            }
            let basis = basis(of: speaker, voice: voice, library: library)
            let yours = speaker == .me || speaker == .others
                ? nil : context.yourVoice(speaker, name: name, voice: voice, basis: basis)
            /// A voice that is probably you is offered Me, and nobody it only sounds like.
            let candidates: [SpeakerCandidate] = switch speaker {
            case .me: context.meCandidates(current: name)
            case .others: context.candidates(for: .others, voice: nil, suggestions: [])
            default: (yours.map { [SpeakerCandidate.me($0.evidence)] } ?? [])
                + context.candidates(for: speaker, voice: voice, suggestions: suggestions, soundsLike: yours == nil)
            }
            return Row(
                speaker: speaker, name: name, basis: basis,
                talkTime: own.reduce(0) { $0 + max(0, $1.end - $1.start) }, lineCount: own.count,
                clips: SpeakerClip.clips(of: speaker, in: lines, excluding: pending),
                candidates: candidates,
                corrections: corrections.filter { $0.from == speaker },
                fusedNames: voice?.identityEvidence?.fusedNames ?? [],
                nameable: speaker != .me && speaker != .others,
                yourVoice: yours?.evidence ?? [], rememberOwner: yours?.remember)
        }
        let attention = rows.filter(\.needsAttention).sorted { $0.talkTime > $1.talkTime }
        let settled = rows.filter { !$0.needsAttention }.sorted { ($0.speaker == .me ? 0 : 1, -$0.talkTime) < ($1.speaker == .me ? 0 : 1, -$1.talkTime) }
        let call = lines.filter { $0.speaker == .others }
        return RecordingSpeakers(
            rows: attention + settled, lines: lines, unclaimedLines: call.count,
            unclaimedTime: call.reduce(0) { $0 + max(0, $1.end - $1.start) },
            callCorrections: corrections.filter { $0.from == .others },
            callCandidates: context.candidates(for: .others, voice: nil, suggestions: []),
            participants: participants, duration: lines.map(\.end).max() ?? 0, context: context)
    }

    static func basis(of speaker: Speaker, voice: RecordingVoices.Voice?, library: VoiceLibrary) -> SpeakerBasis {
        switch speaker {
        case .me: return .microphone
        case .others: return .unnamed
        case .named: return .named
        case .voice: break
        }
        guard let voice else { return .unnamed }
        if voice.namedByOwner == true, voice.name != nil { return .namedByYou }
        let evidence = voice.identityEvidence
        if evidence?.conflict == true { return .uncertain }
        guard let name = voice.name else { return .unnamed }
        if evidence?.resolution != nil { return .review }
        if let evidence {
            switch (evidence.voiceprintName != nil, evidence.callName != nil) {
            case (true, true): return .agreed
            case (true, false): return .voiceMatch
            case (false, true): return .callWindow
            case (false, false): break
            }
        }
        /// No evidence record: a voiceprint match with nothing from the call window, or a
        /// name typed before typed names were recorded. Only a library that backs it says which.
        if let match = library.matchPerson(voice.print), match.person.answers(to: name) || match.person.shownName == name {
            return .voiceMatch
        }
        return .named
    }
}

/// What every candidate list for one recording is worked out against: the names already
/// taken, the person recording's names, and the call window's roster.
struct CandidateContext: Sendable {
    let lines: [Utterance]
    let voices: RecordingVoices?
    let participants: CallParticipants?
    let info: RecordingInfo?
    let library: VoiceLibrary
    let ownerNames: Set<String>
    /// The owner's names from the call window alone, as it spelled them, and normalized.
    let callOwnerDisplayNames: [String]
    let callOwnerNames: Set<String>
    /// Everyone the call window listed, when it could be read for at least half the
    /// recording; nil otherwise, when it says too little about who was not there.
    let knownRoster: [String]?

    /// Similarity a saved voice needs before it is offered as "sounds like".
    static let soundsLikeFloor: Float = 0.3
    static let soundsLikeLimit = 2
    /// The share of the recording the call window has to be readable for before its roster
    /// is taken as everyone who was there.
    static let rosterReadableShare = 0.5

    init(lines: [Utterance], voices: RecordingVoices?, participants: CallParticipants?, info: RecordingInfo?, library: VoiceLibrary) {
        self.lines = lines
        self.voices = voices
        self.participants = participants
        self.info = info
        self.library = library
        let fromCall = ParticipantAttribution.callOwnerNames(participants, lines: lines).sorted()
        var owner = ParticipantAttribution.ownerNames(participants, library: library, lines: lines)
        if let shown = library.owner?.displayName { owner.insert(VoiceLibrary.normalized(shown)) }
        ownerNames = owner
        callOwnerDisplayNames = fromCall
        callOwnerNames = Set(fromCall.map(VoiceLibrary.normalized))
        if let participants, !participants.roster.isEmpty {
            let duration = max(lines.map(\.end).max() ?? 0, participants.observations.map(\.at).max() ?? 0)
            knownRoster = duration > 0 && participants.readable >= Self.rosterReadableShare * duration
                ? participants.roster.map(\.name) : nil
        } else {
            knownRoster = nil
        }
    }

    /// Who Me might be: the library's owner, the names the call window gave the person
    /// recording, and whoever it showed while the microphone's lines were said. Never a name
    /// another speaker carries, never the name Me already has.
    func meCandidates(current: String?) -> [SpeakerCandidate] {
        var offered: [SpeakerCandidate] = []
        if let owner = library.owner { offered.append(SpeakerCandidate(name: owner.shownName, reason: .savedAsYou)) }
        offered += callOwnerDisplayNames.map { SpeakerCandidate(name: $0, reason: .yourCallName) }
        if let shown = shownSpeaking(.me) { offered.append(SpeakerCandidate(name: shown, reason: .yourCallName)) }
        let taken = Set((voices?.voices ?? []).compactMap(\.name).map(VoiceLibrary.normalized))
            .union(current.map { [VoiceLibrary.normalized($0)] } ?? [])
        var seen: Set<String> = []
        return offered.filter { candidate in
            let key = VoiceLibrary.normalized(candidate.name)
            let person = library.person(answering: candidate.name)?.name ?? key
            return !taken.contains(key) && seen.insert(person).inserted
        }
    }

    /// The saved person a speaker is: the one its name belongs to, else the one the voice was
    /// matched to, else the nearest print close enough to claim it.
    func person(named name: String?, voice: RecordingVoices.Voice?) -> VoiceLibrary.Person? {
        if let name, let person = library.people.first(where: { $0.name == name }) ?? library.person(answering: name) {
            return person
        }
        if let saved = voice?.identityEvidence?.voiceprintName, let person = library.people.first(where: { $0.name == saved }) {
            return person
        }
        guard let print = voice?.print, !print.isEmpty else { return nil }
        return library.matchPerson(print)?.person
    }

    /// Whether a speaker is probably the person recording, and why: its name or saved person
    /// is the library's owner; its saved person answers to the owner's name in the call
    /// window; or the call window showed the owner for most of the time it spoke. With the
    /// call window's evidence and no owner in the library yet, who to offer to remember.
    func yourVoice(
        _ speaker: Speaker, name: String?, voice: RecordingVoices.Voice?, basis: SpeakerBasis
    ) -> (evidence: [YourVoiceEvidence], remember: OwnerToRemember?)? {
        let person = person(named: name, voice: voice)
        var evidence: [YourVoiceEvidence] = []
        if person?.isOwner == true || name.map({ library.owner?.answers(to: $0) == true }) == true {
            evidence.append(.savedAsYou)
        }
        if !callOwnerNames.isEmpty, callOwnerNames.contains(where: { owner in
            person?.answers(to: owner) == true || name.map(VoiceLibrary.normalized) == owner
        }) {
            evidence.append(.yourCallName)
        }
        let shown = shownSpeaking(speaker)
        if shown != nil { evidence.append(.shownSpeaking) }
        guard !evidence.isEmpty else { return nil }

        /// Only the call window's word, about someone the library has under another name, is
        /// worth remembering — and not when the owner named this voice themselves, or the
        /// library already has an owner, or the window's name is somebody else's.
        var remember: OwnerToRemember?
        if !evidence.contains(.savedAsYou), basis != .namedByYou, library.owner == nil, let person {
            let display = shown ?? callOwnerDisplayNames.first
            if display.map({ name in !library.people.contains { $0.name != person.name && $0.answers(to: name) } }) ?? true {
                remember = OwnerToRemember(person: person.name, shownName: person.shownName,
                                           display: display.flatMap { person.answers(to: $0) ? nil : $0 })
            }
        }
        return (evidence, remember)
    }

    /// The owner's display name, as the call window spelled it, when the window showed the
    /// owner for most of the time this speaker's lines were indicated: at least three
    /// seconds of it, over two lines or more.
    func shownSpeaking(_ speaker: Speaker) -> String? {
        let spans = participants?.spans ?? []
        guard !spans.isEmpty, !ownerNames.isEmpty else { return nil }
        var mine: [String: Double] = [:]
        var total = 0.0, turns = 0
        for line in lines where line.speaker == speaker {
            var lineMine = 0.0
            for span in spans {
                let overlap = min(line.end, span.end) - max(line.start, span.start)
                guard overlap > 0 else { continue }
                total += overlap
                if span.names.count == 1, ownerNames.contains(VoiceLibrary.normalized(span.names[0])) {
                    mine[span.names[0], default: 0] += overlap
                    lineMine += overlap
                }
            }
            if lineMine >= 0.5 { turns += 1 }
        }
        let owner = mine.values.reduce(0, +)
        guard owner >= ParticipantAttribution.minimumSeconds, turns >= ParticipantAttribution.minimumTurns,
              owner > 0.5 * total else { return nil }
        return mine.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// Whether a saved person is someone the call window listed.
    func inRoster(_ person: VoiceLibrary.Person, roster: [String]) -> Bool {
        roster.contains { person.answers(to: $0) || VoiceLibrary.normalized(person.shownName) == VoiceLibrary.normalized($0) }
    }

    /// Whether two names are one person: the same words, or one library person answering to both.
    func samePerson(_ a: String, _ b: String) -> Bool {
        if VoiceLibrary.normalized(a) == VoiceLibrary.normalized(b) { return true }
        guard let first = library.person(answering: a), let second = library.person(answering: b) else { return false }
        return first.name == second.name
    }

    func isOwner(_ name: String) -> Bool {
        ownerNames.contains(VoiceLibrary.normalized(name))
            || library.person(answering: name).map { person in person.isOwner } == true
    }

    /// Names carried by every speaker but `speaker`.
    func taken(besides speaker: Speaker) -> [String] {
        var names = (voices?.voices ?? []).filter { Speaker.voice($0.letter) != speaker }.compactMap(\.name)
        for line in lines { if case .named(let name) = line.speaker, line.speaker != speaker { names.append(name) } }
        return names
    }

    /// The order is the evidence's strength: what the call window showed for this voice,
    /// then the library and the review, then what the voice said about itself, then who
    /// else was in the call (one left over goes first when the call window named nobody
    /// for this voice), the Slack title, and last the saved voices that are close but not
    /// close enough — only people the call window listed, when its roster is known, and
    /// none when `soundsLike` is off. A name another speaker has, the owner's names, and the
    /// speaker's own name are never offered; one person under two names is offered once.
    func candidates(
        for speaker: Speaker, voice: RecordingVoices.Voice?, suggestions: [SpeakerSuggestion], soundsLike: Bool = true
    ) -> [SpeakerCandidate] {
        let taken = taken(besides: speaker)
        let current: String? = switch speaker {
        case .voice: voice?.name
        case .named(let name): name
        default: nil
        }
        var offered: [SpeakerCandidate] = []
        func offer(_ name: String, _ reason: SpeakerCandidate.Reason) {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !isOwner(name), !taken.contains(where: { samePerson($0, name) }),
                  current.map({ !samePerson($0, name) }) ?? true,
                  !offered.contains(where: { samePerson($0.name, name) }) else { return }
            offered.append(SpeakerCandidate(name: name, reason: reason))
        }
        func shown(_ saved: String) -> String { library.people.first { $0.name == saved }?.shownName ?? saved }

        let evidence = voice?.identityEvidence
        let callNames = evidence.map { ev in (ev.callName.map { [$0] } ?? []) + ev.callNames } ?? []
        let roster = (participants?.roster ?? []).map(\.name)
            .filter { name in !isOwner(name) && !taken.contains { samePerson($0, name) } }
        let leftOver = roster.count == 1 ? roster[0] : nil

        if callNames.isEmpty, let leftOver { offer(leftOver, .onlyOneLeft) }
        for name in callNames { offer(name, .callWindow) }
        if callNames.isEmpty == false, let leftOver { offer(leftOver, .onlyOneLeft) }
        if let voice {
            if let saved = evidence?.voiceprintName {
                offer(shown(saved), .voiceMatch)
            } else if let match = library.matchPerson(voice.print) {
                offer(match.person.shownName, .voiceMatch)
            }
            if let resolved = evidence?.resolution?.name { offer(resolved, .review) }
            for suggestion in suggestions where suggestion.letter == voice.letter {
                offer(suggestion.name, .introduced(quote: suggestion.quote))
            }
        }
        for name in roster { offer(name, .inCall) }
        for name in titleNames { offer(name, .windowTitle) }
        if soundsLike, let voice, !voice.print.isEmpty {
            let close = library.people.compactMap { person -> (VoiceLibrary.Person, Float)? in
                /// Someone not in a call whose roster is known was not there to speak.
                if let knownRoster, !inRoster(person, roster: knownRoster) { return nil }
                guard let nearest = person.prints.map({ VoiceLibrary.similarity($0, voice.print) }).max(),
                      nearest >= Self.soundsLikeFloor, nearest < VoiceLibrary.threshold else { return nil }
                return (person, nearest)
            }
            .sorted { $0.1 > $1.1 }
            var added = 0
            for (person, _) in close where added < Self.soundsLikeLimit {
                let before = offered.count
                offer(person.shownName, .soundsLike)
                if offered.count > before { added += 1 }
            }
        }
        return offered
    }

    /// Slack titles a huddle after the people in it: "First Last, Other Person - Workspace -
    /// 2 new items - Slack". Other apps' titles say nothing reliable about who is there.
    var titleNames: [String] { Self.titleNames(info) }

    static func titleNames(_ info: RecordingInfo?) -> [String] {
        guard let info, info.bundleID == "com.tinyspeck.slackmacgap" else { return [] }
        let cleaned = RecordingMedia.cleanTitle(info.title, app: "Slack")
        guard let first = cleaned.split(separator: #/\s+[-–—|]\s+/#).first else { return [] }
        return first.components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

/// The changes the Speakers panel, the transcript's label popovers and the terminal make.
/// Each changes the speakers layer and, for a whole voice named, the library; nothing else.
public enum SpeakerEditing {
    /// Names a whole voice through `VoiceNaming`, which files its print under the name.
    /// `learnCallName` is false when the owner picked a name other than the one the call
    /// window showed: that display name was then wrong, not this person's alias. A
    /// speaker with no voice record (a name typed for lines) is renamed line by line.
    /// `person` is the saved name of the library person the name was picked or typed as
    /// (`RecordingSpeakers.completions`, `person(for:typed:)`): the print is filed under
    /// them, never under a new record.
    @discardableResult
    public static func name(
        _ speaker: Speaker, _ name: String, in directory: URL, learnCallName: Bool = true,
        person: String? = nil, library: URL = VoiceLibrary.directory
    ) throws -> [URL] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if case .voice(let letter) = speaker, RecordingVoices.read(in: directory)?.voices.contains(where: { $0.letter == letter }) == true {
            return try VoiceNaming.apply([letter: trimmed], in: directory, library: library, learnCallName: learnCallName,
                                         people: person.map { [letter: $0] } ?? [:]).written
        }
        guard let current = RecordingTranscript.read(in: directory) else { return [] }
        let lines = current.transcript.utterances.indices.filter { current.transcript.utterances[$0].speaker == speaker }
        return try reassign(lines, to: self.speaker(named: trimmed, in: current.voices), in: directory)
    }

    /// Gives every line of a speaker to Me — the whole-voice "Me" a speaker that is probably
    /// the person recording is offered. With `remember`, which the owner ticked, that saved
    /// person also becomes the library's owner and the call window's name for them is filed
    /// as their alias; without it the owner is not changed. The voice's print is handled as
    /// `give` handles it.
    @discardableResult
    public static func giveToMe(
        _ speaker: Speaker, in directory: URL, remember: OwnerToRemember? = nil, library: URL = VoiceLibrary.directory
    ) throws -> [URL] {
        try give(speaker, to: .me, in: directory, remember: remember, library: library)
    }

    /// Gives every line of a speaker to `target` — Me, Call or another speaker — in the
    /// speakers layer; the summary then says it is stale. A lettered voice no longer carries
    /// its name, and what the owner's naming of it filed in the library is taken back
    /// (`VoiceNaming.takeBack`): the wrong person stops matching this voice. Given to Me,
    /// its print joins the library owner's, so the owner's voice is recognised next time;
    /// with no owner it is filed nowhere. Prints from other recordings are never touched.
    @discardableResult
    public static func give(
        _ speaker: Speaker, to target: Speaker, in directory: URL, remember: OwnerToRemember? = nil,
        library: URL = VoiceLibrary.directory
    ) throws -> [URL] {
        guard speaker != target, speaker != .me, let current = RecordingTranscript.read(in: directory) else { return [] }
        let lines = current.transcript.utterances.indices.filter { current.transcript.utterances[$0].speaker == speaker }
        guard !lines.isEmpty else { return [] }
        var saved = VoiceLibrary.load(from: library)
        let before = saved
        var voice: RecordingVoices.Voice?
        if case .voice(let letter) = speaker { voice = current.voices?.voices.first { $0.letter == letter } }
        /// Taken back first, so the owner remembered next can keep a name the naming added.
        let made = voice.flatMap { VoiceNaming.takeBack($0, from: &saved) }
        if let remember, saved.people.contains(where: { $0.name == remember.person }) {
            saved.setOwner(remember.person)
            if let display = remember.display { saved.addAlias(display, to: remember.person) }
        }
        var filing: RecordingVoices.Voice.Filing?
        if target == .me, let voice, let owner = saved.owner,
           let filed = saved.file(owner.name, voice.print,
                                  origin: .init(recording: RecordingLayout(directory: directory).identity)) {
            filing = .init(person: filed.name, createdPerson: false)
        }
        if let made { saved.removeIfEmpty(made) }
        let written = try TranscriptStore.updateSpeakers(in: directory) { layer, current in
            var speakers = layer.speakers ?? current.transcript.utterances.map(\.speaker)
            guard lines.allSatisfy(speakers.indices.contains) else {
                throw TranscriptionError.engineFailed(engine: "transcript", log: "The transcript changed. Reopen this recording and try again.")
            }
            for line in lines { speakers[line] = target }
            layer.speakers = speakers
            if let voice, let index = layer.voices?.voices.firstIndex(where: { $0.letter == voice.letter }) {
                layer.voices?.unname(voice.letter)
                layer.voices?.voices[index].filed = filing
            }
            if let remember, saved.owner?.name == remember.person {
                layer.voices = RecordingVoices.withMe(layer.voices, named: remember.shownName)
            }
        }
        if saved != before { try saved.save(to: library) }
        return written
    }

    /// The owner says who they are: Me is called `name` in this recording, and the library
    /// marks that person as its owner, so later transcripts start with the name and the
    /// owner's voice is recognised as theirs. `person` is the saved person a picked
    /// completion or candidate stands for; without one, a person answering to the name is
    /// used, else a new record is made (no print: a name is not a voice). An explicit choice,
    /// like the remember-me tick; nothing else sets the owner.
    @discardableResult
    public static func nameMe(
        _ name: String, person: String? = nil, in directory: URL, library: URL = VoiceLibrary.directory
    ) throws -> [URL] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        var saved = VoiceLibrary.load(from: library)
        let before = saved
        let existing = person.flatMap { wanted in saved.people.first { $0.name == wanted } }
            ?? saved.person(answering: name)
        let owner = existing?.name ?? saved.addPerson(named: name)
        saved.setOwner(owner)
        if VoiceLibrary.normalized(owner) != VoiceLibrary.normalized(name) { saved.addAlias(name, to: owner) }
        let written = try TranscriptStore.updateSpeakers(in: directory) { layer, _ in
            layer.voices = RecordingVoices.withMe(layer.voices, named: name)
        }
        if saved != before { try saved.save(to: library) }
        return written
    }

    /// The speaker a name means in this recording: the voice that carries it, else the name
    /// itself on the lines it is given to.
    public static func speaker(named name: String, in voices: RecordingVoices?) -> Speaker {
        let key = VoiceLibrary.normalized(name)
        if let voice = voices?.voices.first(where: { $0.name.map(VoiceLibrary.normalized) == key }) { return .voice(voice.letter) }
        return .named(name)
    }

    /// Gives these lines to `speaker` in the speakers layer and changes nothing else: not
    /// the sources, the wording or the summary file, which says it is stale because who
    /// said what changed. Prints are never filed for a line.
    @discardableResult
    public static func reassign(_ lines: [Int], to speaker: Speaker, in directory: URL) throws -> [URL] {
        guard !lines.isEmpty else { return [] }
        return try TranscriptStore.updateSpeakers(in: directory) { layer, current in
            var speakers = layer.speakers ?? current.transcript.utterances.map(\.speaker)
            guard lines.allSatisfy(speakers.indices.contains) else {
                throw TranscriptionError.engineFailed(engine: "transcript", log: "The transcript changed. Reopen this recording and try again.")
            }
            for line in lines { speakers[line] = speaker }
            layer.speakers = speakers
        }
    }
}
