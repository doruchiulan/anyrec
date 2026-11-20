import Foundation

/// What keeps a wrong print out of the library, and finds the ones already in it. A print
/// filed under the wrong person names that person on every later call, so the owner's
/// confirmation is necessary but not enough: the voice also has to be one person, heard for
/// long enough, and not somebody else the library already knows. A print that passes but
/// does not sound like the person's other prints waits (`Person.waiting`) until a second
/// one agrees. Found on a real library: the owner's two prints were 0.10 alike, one of them
/// matched the owner's microphone at 0.77 and the other at 0.15, and nothing had noticed.
extension VoiceLibrary {
    /// Whether a print may be filed, and why not.
    public enum Admission: Equatable, Sendable, Codable {
        /// Filed with the person's prints.
        case filed
        /// Unlike the person's other prints: kept aside, not matched, until another agrees.
        case waiting
        /// It agreed with a waiting print, and both joined the person's prints.
        case confirmed
        /// Too little speech for a print worth keeping.
        case tooShort
        /// The call window showed more than one person while this voice spoke.
        case mixed
        /// It sounds like someone else in the library.
        case soundsLike(String)
    }

    /// Speech under this, in seconds, makes a centroid too unsteady to keep.
    public static let minimumSeconds: TimeInterval = 20
    /// Below this to all of a person's prints, a new one is unlike them and waits.
    public static let probationFloor: Float = 0.3
    /// Two people this alike are probably one.
    public static let duplicateFloor: Float = 0.8

    /// Files `print` under `name` when it is safe to: the voice spoke for `seconds`, the
    /// call window did not see several people in it (`mixed`), it does not match someone
    /// else better, and it is like the person's other prints. Nothing is filed otherwise,
    /// and the reason is returned for the interface to word. Who the print goes to is
    /// resolved as `file` resolves it.
    @discardableResult
    public mutating func consider(
        _ name: String, _ print: Voiceprint, origin: PrintOrigin? = nil,
        seconds: TimeInterval? = nil, mixed: Bool = false
    ) -> (filing: (name: String, created: Bool)?, admission: Admission) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !print.isEmpty else { return (nil, .tooShort) }
        /// How much speech the print stands for, which curation weighs it by.
        let origin = origin.map { var weighed = $0; weighed.seconds = seconds ?? weighed.seconds; return weighed }
        if let seconds, seconds < Self.minimumSeconds { return (nil, .tooShort) }
        if mixed { return (nil, .mixed) }
        let target = people.firstIndex(where: { $0.name == name })
            ?? person(answering: name).flatMap { found in people.firstIndex { $0.name == found.name } }
        let own = target.map { people[$0].prints.map { Self.similarity($0, print) }.max() ?? -1 } ?? -1
        if let other = nearestOther(than: target, to: print), other.similarity >= Self.threshold, other.similarity > own {
            return (nil, .soundsLike(other.person.shownName))
        }
        guard let index = target else { return (file(name, print, origin: origin), .filed) }
        if people[index].prints.contains(print) { return ((people[index].name, false), .filed) }
        if people[index].prints.isEmpty || own >= Self.probationFloor {
            people[index].admit(print, origin: origin)
            return ((people[index].name, false), .filed)
        }
        if let agreeing = people[index].waiting.firstIndex(where: { Self.similarity($0, print) >= Self.probationFloor }) {
            let earlier = people[index].waiting.remove(at: agreeing)
            let earlierOrigin = people[index].waitingOrigins.indices.contains(agreeing) ? people[index].waitingOrigins.remove(at: agreeing) : nil
            people[index].admit(earlier, origin: earlierOrigin)
            people[index].admit(print, origin: origin)
            return ((people[index].name, false), .confirmed)
        }
        if !people[index].waiting.contains(print) {
            people[index].waiting.append(print)
            people[index].waitingOrigins.append(origin)
        }
        return ((people[index].name, false), .waiting)
    }

    /// The closest person other than the one at `index`, by their nearest print.
    func nearestOther(than index: Int?, to print: Voiceprint) -> (person: Person, similarity: Float)? {
        people.indices.filter { $0 != index }.compactMap { other -> (Person, Float)? in
            guard let nearest = people[other].prints.map({ Self.similarity($0, print) }).max() else { return nil }
            return (people[other], nearest)
        }
        .max { $0.1 < $1.1 }
    }

    /// The owner said a voice the library matched to `name` is somebody else: the print of
    /// theirs that made the match goes on probation, so it stops naming this voice without
    /// being thrown away — it may still be them on a better day. Returns whether one moved.
    @discardableResult
    public mutating func demote(nearestTo print: Voiceprint, in name: String) -> Bool {
        guard let index = people.firstIndex(where: { $0.name == name }), !print.isEmpty,
              let nearest = people[index].prints.indices.max(by: {
                  Self.similarity(people[index].prints[$0], print) < Self.similarity(people[index].prints[$1], print)
              }),
              Self.similarity(people[index].prints[nearest], print) >= Self.threshold else { return false }
        let origin = people[index].origin(ofPrint: nearest)
        let moved = people[index].prints[nearest]
        people[index].removePrint(at: nearest)
        people[index].waiting.append(moved)
        people[index].waitingOrigins.append(origin)
        return true
    }

    // MARK: Health

    /// Something in the library worth one plain question.
    public enum Issue: Equatable, Sendable {
        /// Two records that sound like one person.
        case samePerson(String, String, similarity: Float)
        /// A print unlike the rest of its person's prints.
        case unlike(person: String, print: Int)
    }

    /// Records that are probably one person, unless the owner said they are not, and
    /// prints that do not sound like the rest of their person's.
    public var issues: [Issue] {
        var found: [Issue] = []
        for (a, b) in people.indices.flatMap({ a in people.indices.filter { $0 > a }.map { (a, $0) } }) {
            let first = people[a], second = people[b]
            guard !first.notSameAs.contains(second.name), !second.notSameAs.contains(first.name) else { continue }
            let closest = first.prints.flatMap { p in second.prints.map { Self.similarity(p, $0) } }.max() ?? 0
            if closest >= Self.duplicateFloor { found.append(.samePerson(first.name, second.name, similarity: closest)) }
        }
        for person in people where person.prints.count > 1 {
            for index in person.prints.indices {
                let others = person.prints.indices.filter { $0 != index }.map { Self.similarity(person.prints[$0], person.prints[index]) }
                if let best = others.max(), best < Self.probationFloor {
                    found.append(.unlike(person: person.name, print: index))
                }
            }
        }
        return found
    }

    /// One person under two records: `duplicate`'s prints, waiting prints and names join
    /// `main`, its saved name stays as a nickname, and the record goes. The owner flag goes
    /// with it if `duplicate` had it.
    public mutating func mergePerson(_ duplicate: String, into main: String) {
        guard duplicate != main, let from = people.first(where: { $0.name == duplicate }),
              people.contains(where: { $0.name == main }) else { return }
        forget(duplicate)
        guard let index = people.firstIndex(where: { $0.name == main }) else { return }
        for at in from.prints.indices where !people[index].prints.contains(from.prints[at]) {
            people[index].admit(from.prints[at], origin: from.origin(ofPrint: at))
        }
        for (at, print) in from.waiting.enumerated() where !people[index].waiting.contains(print) {
            people[index].waiting.append(print)
            people[index].waitingOrigins.append(from.waitingOrigins.indices.contains(at) ? from.waitingOrigins[at] : nil)
        }
        if from.isOwner { setOwner(main) }
        for name in [from.name] + from.aliases + [from.displayName].compactMap({ $0 }) { addAlias(name, to: main) }
    }

    /// The owner said these two are different people: never ask about the pair again.
    public mutating func markDifferent(_ a: String, _ b: String) {
        guard let first = people.firstIndex(where: { $0.name == a }), let second = people.firstIndex(where: { $0.name == b }) else { return }
        if !people[first].notSameAs.contains(b) { people[first].notSameAs.append(b) }
        if !people[second].notSameAs.contains(a) { people[second].notSameAs.append(a) }
    }
}
