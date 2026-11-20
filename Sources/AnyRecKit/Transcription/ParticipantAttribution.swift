import Foundation

public struct SpeakerIdentityEvidence: Codable, Equatable, Sendable {
    public struct Resolution: Codable, Equatable, Sendable {
        public let name: String
        public let reason: String
        public let provider: SummaryProvider
    }

    public let callNames: [String]
    public let voiceprintName: String?
    public var conflict: Bool
    public var resolution: Resolution? = nil
    /// The display name the call window pointed at for this voice, when one did.
    public var callName: String? = nil
    /// How consistently the indicators pointed at `callName` where there were any, and
    /// over how many seconds.
    public var agreement: Double? = nil
    public var evidenceSeconds: Double? = nil
    /// Indicators repeatedly showed these different people inside this one voice: the
    /// diarizer has probably fused them. A fact to show; nothing is split.
    public var fusedNames: [String]? = nil

    public init(callNames: [String], voiceprintName: String?, conflict: Bool, resolution: Resolution? = nil) {
        self.callNames = callNames
        self.voiceprintName = voiceprintName
        self.conflict = conflict
        self.resolution = resolution
    }
}

/// Names from the call window, laid over the voices the diarizer told apart.
///
/// The call window's speaking indicator is scored by how consistently it pointed at one
/// person wherever it could be read, not by how much of a voice's speech it covered: a
/// Slack tile that is readable for the first minute and a half still says who spoke in
/// that minute and a half. A poll marking several people can agree with a name but never
/// supply one. A display name that corroborates a voiceprint is agreement — the saved
/// name stays and the display name is learned as an alias — and it is a conflict only
/// when the display name belongs to someone else, or two display names compete. The
/// wrong name is the worse mistake, so every threshold errs towards leaving a letter.
enum ParticipantAttribution {
    struct Result {
        var voices: RecordingVoices?
        var lines: [Utterance]
        /// Display names a call window showed for a known person: filed as aliases when new,
        /// and remembered as the name later transcripts use (`VoiceLibrary.noteCallName`).
        var aliases: [(display: String, person: String)] = []
    }

    /// Floors under which call evidence for a voice is not read at all.
    static let minimumSeconds = 3.0
    static let minimumTurns = 2
    static let minimumEvidence = 4.0
    /// The share of a voice's indicated time that has to point at one person.
    static let agreement = 0.85
    /// A voice is the person recording when at least this share of what the diarizer
    /// heard from it lies inside lines the microphone measured as theirs.
    static let ownerShare = 0.5
    static let ownerSeconds = 5.0

    static func apply(_ voices: RecordingVoices?, lines: [Utterance], evidence: CallParticipants?) -> RecordingVoices? {
        resolve(voices, lines: lines, evidence: evidence, library: VoiceLibrary(), microphone: nil).voices
    }

    static func resolve(
        _ voices: RecordingVoices?, lines: [Utterance], evidence: CallParticipants?,
        library: VoiceLibrary, microphone: SpeakerAttribution.Microphone?
    ) -> Result {
        guard var result = voices else { return Result(voices: nil, lines: lines) }
        let spans = evidence?.spans ?? []
        var aliases: [(String, String)] = []
        var scores: [String: Score] = [:]

        for index in result.voices.indices {
            let voice = result.voices[index]
            let score = Self.score(lines.filter { $0.speaker == .voice(voice.letter) }, among: lines, spans: spans)
            scores[voice.letter] = score
            guard score.best != nil || !score.candidates.isEmpty || !score.fused.isEmpty else { continue }
            let matched = voice.name.map { name in library.people.first { $0.name == name } ?? .init(name: name, prints: []) }
            var name = voice.name
            var conflict = false
            if let display = score.best {
                let owner = library.person(answering: display)
                if let matched {
                    if matched.answers(to: display) {
                        name = matched.name
                        if VoiceLibrary.normalized(display) != VoiceLibrary.normalized(matched.name) {
                            aliases.append((display, matched.name))
                        }
                    } else if let owner, owner.name != matched.name {
                        conflict = true
                        name = nil
                    } else {
                        name = matched.name
                        aliases.append((display, matched.name))
                    }
                } else {
                    name = owner?.name ?? display
                    if let owner, VoiceLibrary.normalized(display) != VoiceLibrary.normalized(owner.name) {
                        aliases.append((display, owner.name))
                    }
                }
            } else if score.candidates.count > 1 {
                conflict = matched.map { person in !score.candidates.contains(where: person.answers) } ?? true
            }
            var record = SpeakerIdentityEvidence(callNames: score.best.map { [$0] } ?? score.candidates,
                                                 voiceprintName: voice.name, conflict: conflict)
            record.callName = score.best
            record.agreement = score.best.map { score.agreement(for: $0) }
            record.evidenceSeconds = score.total
            record.fusedNames = score.fused.count > 1 ? score.fused : nil
            result.voices[index].identityEvidence = record
            result.voices[index].name = name
        }
        rejectDuplicateNames(&result)

        /// A display name the call window showed for the person recording is theirs, not the
        /// alias of whoever a voiceprint matched: unflagged, the owner can look like anyone.
        let ownDisplayNames = ownerNames(evidence, library: library, lines: lines)
        aliases.removeAll { alias in
            ownDisplayNames.contains(VoiceLibrary.normalized(alias.0))
                && library.people.first(where: { $0.name == alias.1 })?.isOwner != true
        }

        var lines = lines
        if let microphone {
            let owners = ownerLetters(result, lines: lines, evidence: evidence, library: library, scores: scores)
            if !owners.letters.isEmpty {
                let merge = mergeOwner(owners, into: &lines, voices: result, spans: spans, microphone: microphone)
                result.voices.removeAll { owners.letters.contains($0.letter) }
                result.ownerMerge = merge
            }
        }
        let owners = ownerNames(evidence, library: library, lines: lines)
        let named = nameCallLines(&lines, voices: result, spans: spans, owners: owners)
            + nameCallLinesForOnlyOther(&lines, voices: result, evidence: evidence, owners: owners)
        if named > 0 { result.callLinesNamed = named }
        /// Engine labels (OpenAI's) are kept as the engine gave them; only a voice given
        /// back to the owner leaves a gap worth closing.
        if result.ownerMerge != nil { renumber(&lines, &result) }
        showDisplayNames(&result, library: library)
        return Result(voices: result, lines: lines, aliases: aliases)
    }

    /// The names a transcript shows, settled last so every check above still compares
    /// saved names. A person the call window showed in this recording is called what it
    /// showed; one it did not show takes the display name learned on an earlier call;
    /// otherwise the saved name stays. A name somebody types later beats all of these.
    static func showDisplayNames(_ voices: inout RecordingVoices, library: VoiceLibrary) {
        for index in voices.voices.indices {
            let voice = voices.voices[index]
            guard let name = voice.name, voice.identityEvidence?.conflict != true,
                  let person = library.people.first(where: { $0.name == name }) else { continue }
            /// Not a conflict, so the call name is this person: one of their aliases, or a new
            /// one being filed now, but never a name that belongs to somebody else.
            if let shown = voice.identityEvidence?.callName,
               !library.people.contains(where: { $0.name != name && $0.answers(to: shown) }),
               VoiceLibrary.normalized(shown) != VoiceLibrary.normalized(name) {
                voices.voices[index].name = shown
            } else if let learned = person.displayName {
                voices.voices[index].name = learned
            }
        }
    }

    // MARK: - Scoring

    struct Score {
        var single: [String: Double] = [:]
        var multi: [String: Double] = [:]
        var turns: [String: Int] = [:]
        var total = 0.0

        func agreement(for name: String) -> Double {
            total > 0 ? ((single[name] ?? 0) + (multi[name] ?? 0)) / total : 0
        }

        private func supported(_ name: String) -> Bool {
            (single[name] ?? 0) >= ParticipantAttribution.minimumSeconds
                && (turns[name] ?? 0) >= ParticipantAttribution.minimumTurns
        }

        /// The one person the indicators consistently showed, if there was one.
        var best: String? {
            guard total >= ParticipantAttribution.minimumEvidence,
                  let top = single.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key,
                  supported(top), agreement(for: top) >= ParticipantAttribution.agreement else { return nil }
            return top
        }

        /// Everyone with sustained evidence of their own, when no one person wins.
        var candidates: [String] {
            best == nil ? single.keys.filter(supported).sorted() : []
        }

        /// People who each hold a real share of the voice's indicated time.
        var fused: [String] {
            let singles = single.values.reduce(0, +)
            return single.filter { $0.value >= max(5, 0.2 * singles) && (turns[$0.key] ?? 0) >= ParticipantAttribution.minimumTurns }.keys.sorted()
        }
    }

    /// Indicators over a voice's own clean lines: long enough, overlapped by nobody else,
    /// with a margin at each end for the tile catching up.
    static func score(_ own: [Utterance], among lines: [Utterance], spans: [CallParticipants.Span]) -> Score {
        var score = Score()
        guard !spans.isEmpty else { return score }
        let clean = own.filter { line in
            line.start.isFinite && line.end.isFinite && line.start >= 0 && line.end - line.start >= 1.0
                && !lines.contains { $0.speaker != line.speaker && $0.start < line.end && $0.end > line.start }
        }
        var previousEnd = 0.0
        for line in clean.sorted(by: { $0.start < $1.start }) {
            let start = max(line.start + 0.35, previousEnd), end = line.end - 0.35
            guard end > start else { continue }
            previousEnd = end
            var heard: [String: Double] = [:]
            for span in spans.near(start, end) {
                let overlap = min(end, span.end) - max(start, span.start)
                guard overlap > 0 else { continue }
                score.total += overlap
                if span.names.count == 1 {
                    heard[span.names[0], default: 0] += overlap
                } else {
                    for name in span.names { score.multi[name, default: 0] += overlap }
                }
            }
            for (name, amount) in heard {
                score.single[name, default: 0] += amount
                if amount >= 0.5 { score.turns[name, default: 0] += 1 }
            }
        }
        return score
    }

    /// The person a stretch of time was indicated as, when exactly one was shown for most
    /// of it and nobody else for any real part of it.
    static func indicated(from start: TimeInterval, to end: TimeInterval, spans: [CallParticipants.Span]) -> String? {
        let length = end - start
        guard length > 0 else { return nil }
        var heard: [String: Double] = [:]
        var others = 0.0
        for span in spans.near(start, end) {
            let overlap = min(end, span.end) - max(start, span.start)
            guard overlap > 0 else { continue }
            if span.names.count == 1 { heard[span.names[0], default: 0] += overlap } else { others += overlap }
        }
        guard let top = heard.max(by: { $0.value < $1.value }), top.value >= 0.6 * length,
              heard.filter({ $0.key != top.key }).values.reduce(others, +) <= 0.1 * length else { return nil }
        return top.key
    }

    // MARK: - The person recording

    struct Owners {
        var letters: Set<String> = []
        var evidence: Set<RecordingVoices.OwnerMerge.Evidence> = []
        var names: Set<String> = []
    }

    /// The person recording's display names: their own tile where the app labels it, the
    /// library's owner, and whoever the indicators showed while the microphone measured
    /// speech — which is exact, because "Me" is measured, not guessed.
    static func ownerNames(_ evidence: CallParticipants?, library: VoiceLibrary, lines: [Utterance]) -> Set<String> {
        var names = callOwnerNames(evidence, lines: lines)
        if let owner = library.owner { names.formUnion([owner.name] + owner.aliases) }
        return Set(names.map(VoiceLibrary.normalized))
    }

    /// The owner's display names from the call window alone, as it spelled them: their own
    /// tile, and — only when the window labels no tile as theirs (Slack) — whoever it showed
    /// speaking during Me lines. With a tile, a different name shown during Me lines is
    /// someone else at the same microphone: on a Teams call taken from one room, the colleague
    /// beside the owner was shown speaking from their own laptop, became one of the owner's
    /// names, was learned as the owner's display name, and every later call called the owner
    /// by it.
    static func callOwnerNames(_ evidence: CallParticipants?, lines: [Utterance]) -> Set<String> {
        var names = evidence?.selfNames ?? []
        if names.isEmpty, let evidence,
           let mine = score(lines.filter { $0.speaker == .me }, among: lines, spans: evidence.spans).best {
            names.insert(mine)
        }
        return names
    }

    /// Whether the call window showed the person recording over a stretch: one of `owners`
    /// marked alone speaking for at least half a second, and for at least twice as long as
    /// anyone else, or several people together, were.
    static func showsOwner(from start: TimeInterval, to end: TimeInterval, spans: [CallParticipants.Span], owners: Set<String>) -> Bool {
        var mine = 0.0, others = 0.0
        for span in spans.near(start, end) {
            let overlap = min(end, span.end) - max(start, span.start)
            guard overlap > 0 else { continue }
            if span.names.count == 1, owners.contains(VoiceLibrary.normalized(span.names[0])) { mine += overlap } else { others += overlap }
        }
        return mine >= 0.5 && mine >= 2 * others
    }

    static func ownerLetters(
        _ voices: RecordingVoices, lines: [Utterance], evidence: CallParticipants?, library: VoiceLibrary,
        scores: [String: Score]
    ) -> Owners {
        let names = ownerNames(evidence, library: library, lines: lines)
        var owners = Owners(names: names)
        for voice in voices.voices {
            var why: [RecordingVoices.OwnerMerge.Evidence] = []
            if let share = voice.microphoneShare, share >= ownerShare, (voice.microphoneSeconds ?? 0) >= ownerSeconds {
                why.append(.microphone)
            }
            if let owner = library.owner, let name = voice.identityEvidence?.voiceprintName ?? voice.name,
               owner.name == name, voice.identityEvidence?.callName.map({ !names.contains(VoiceLibrary.normalized($0)) }) != true {
                why.append(.voiceprint)
            }
            if let call = scores[voice.letter]?.best, names.contains(VoiceLibrary.normalized(call)) {
                why.append(.callWindow)
            }
            guard !why.isEmpty else { continue }
            owners.letters.insert(voice.letter)
            owners.evidence.formUnion(why)
        }
        return owners
    }

    /// A line of the owner's voice goes to the person the call window showed when it showed
    /// only someone else, and never to "Me" while the call could not hear the microphone:
    /// putting the far end's words in the owner's mouth is the worse mistake. Otherwise it
    /// goes back to "Me" when the microphone carried speech or the call window showed the
    /// owner speaking. The second is for speakerphone: a bleeding microphone is held under
    /// the call, so where the owner talks over or straight after the far end the mix — what
    /// "carrying speech" is judged on — holds it down, and those lines failed the first
    /// test although the diarizer heard the owner's voice in them. Everything else goes to
    /// the call.
    static func mergeOwner(
        _ owners: Owners, into lines: inout [Utterance], voices: RecordingVoices, spans: [CallParticipants.Span],
        microphone: SpeakerAttribution.Microphone
    ) -> RecordingVoices.OwnerMerge {
        let letters = letterFor(voices, excluding: owners.letters)
        var toMe = 0, toOthers = 0
        for index in lines.indices {
            guard case .voice(let letter) = lines[index].speaker, owners.letters.contains(letter) else { continue }
            let line = lines[index]
            if let shown = indicated(from: line.start, to: line.end, spans: spans),
               !owners.names.contains(VoiceLibrary.normalized(shown)) {
                lines[index].speaker = letters[VoiceLibrary.normalized(shown)].map { .voice($0) } ?? .others
                toOthers += 1
            } else if microphone.isLive(from: line.start, to: line.end),
                      microphone.speaks(from: line.start, to: line.end)
                        || showsOwner(from: line.start, to: line.end, spans: spans, owners: owners.names) {
                lines[index].speaker = .me
                toMe += 1
            } else {
                lines[index].speaker = .others
                toOthers += 1
            }
        }
        return .init(evidence: owners.evidence.sorted { $0.rawValue < $1.rawValue }, toMe: toMe, toOthers: toOthers)
    }

    // MARK: - Lines no voice covered

    /// A "Call" line — one no diarized voice covered — takes the person the call window
    /// showed when that is unambiguous and maps to a voice of this recording.
    static func nameCallLines(
        _ lines: inout [Utterance], voices: RecordingVoices, spans: [CallParticipants.Span], owners: Set<String>
    ) -> Int {
        guard !spans.isEmpty else { return 0 }
        let letters = letterFor(voices, excluding: [])
        var named = 0
        for index in lines.indices where lines[index].speaker == .others {
            guard let shown = indicated(from: lines[index].start, to: lines[index].end, spans: spans),
                  !owners.contains(VoiceLibrary.normalized(shown)),
                  let letter = letters[VoiceLibrary.normalized(shown)] else { continue }
            lines[index].speaker = .voice(letter)
            named += 1
        }
        return named
    }

    /// In a call of two, a line from the call is the other person's, whoever the window showed
    /// speaking. A real 1:1 left seven of Costin's lines as "Call" after the diarizer heard him
    /// and the owner as one voice and gave it back to the owner. Only when the call window was
    /// readable for at least half the recording, so its roster is everyone who was there, and
    /// the owner's names leave exactly one person in it. The lines go to the voice that carries
    /// that name, else to the name itself, unless an unnamed voice could still turn out to be
    /// them: then the Call row offers the name instead.
    static func nameCallLinesForOnlyOther(
        _ lines: inout [Utterance], voices: RecordingVoices, evidence: CallParticipants?, owners: Set<String>
    ) -> Int {
        guard let evidence, let other = onlyOther(in: evidence, owners: owners, lines: lines) else { return 0 }
        let letter = letterFor(voices, excluding: [])[VoiceLibrary.normalized(other)]
        guard letter != nil || voices.unnamed.isEmpty else { return 0 }
        var named = 0
        let spans = evidence.spans
        for index in lines.indices where lines[index].speaker == .others {
            /// Not where the window showed the owner: that line stays for the owner to decide.
            guard !showsOwner(from: lines[index].start, to: lines[index].end, spans: spans, owners: owners)
            else { continue }
            lines[index].speaker = letter.map { .voice($0) } ?? .named(other)
            named += 1
        }
        return named
    }

    /// The one person in the call who is not the owner, when the window's roster can be
    /// trusted to be everyone (readable for half the recording) and says so.
    static func onlyOther(in evidence: CallParticipants, owners: Set<String>, lines: [Utterance]) -> String? {
        guard !owners.isEmpty else { return nil }
        let duration = max(lines.map(\.end).max() ?? 0, evidence.observations.map(\.at).max() ?? 0)
        guard duration > 0, evidence.readable >= CandidateContext.rosterReadableShare * duration else { return nil }
        let others = evidence.roster.map(\.name).filter { !owners.contains(VoiceLibrary.normalized($0)) }
        return others.count == 1 ? others[0] : nil
    }

    /// Display name → letter, for every voice whose call name or name says who it is, and
    /// only where one voice answers to it.
    private static func letterFor(_ voices: RecordingVoices, excluding: Set<String>) -> [String: String] {
        var map: [String: Set<String>] = [:]
        for voice in voices.voices where !excluding.contains(voice.letter) {
            let names = [voice.name, voice.identityEvidence?.callName].compactMap { $0 }
            for name in names { map[VoiceLibrary.normalized(name), default: []].insert(voice.letter) }
        }
        return map.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    // MARK: - Bookkeeping

    /// A name the call window gave to two voices cannot be both of them. Voices named by
    /// the call window alone give it up; voiceprint matches are left as they were.
    private static func rejectDuplicateNames(_ result: inout RecordingVoices) {
        let groups = Dictionary(grouping: result.voices.filter { $0.name != nil }, by: { VoiceLibrary.normalized($0.name!) })
        for index in result.voices.indices {
            let voice = result.voices[index]
            guard let name = voice.name, groups[VoiceLibrary.normalized(name), default: []].count > 1,
                  let evidence = voice.identityEvidence, evidence.voiceprintName == nil else { continue }
            result.voices[index].name = nil
            var record = SpeakerIdentityEvidence(callNames: evidence.callNames, voiceprintName: nil, conflict: true)
            record.callName = evidence.callName
            record.agreement = evidence.agreement
            record.evidenceSeconds = evidence.evidenceSeconds
            record.fusedNames = evidence.fusedNames
            result.voices[index].identityEvidence = record
        }
    }

    /// Letters again by first appearance, so a voice given back to the owner leaves no gap
    /// and a transcript never opens on "Speaker B".
    private static func renumber(_ lines: inout [Utterance], _ voices: inout RecordingVoices) {
        var letters: [String: String] = [:]
        for line in lines.sorted(by: { $0.start < $1.start }) {
            guard case .voice(let heard) = line.speaker, letters[heard] == nil else { continue }
            letters[heard] = VoiceSeparation.letter(letters.count)
        }
        for voice in voices.voices where letters[voice.letter] == nil {
            letters[voice.letter] = VoiceSeparation.letter(letters.count)
        }
        guard letters.contains(where: { $0.key != $0.value }) else { return }
        for index in lines.indices {
            if case .voice(let heard) = lines[index].speaker, let renamed = letters[heard] { lines[index].speaker = .voice(renamed) }
        }
        voices.voices = voices.voices.map { $0.relettered(letters[$0.letter] ?? $0.letter) }
            .sorted { ($0.letter.count, $0.letter) < ($1.letter.count, $1.letter) }
    }
}
