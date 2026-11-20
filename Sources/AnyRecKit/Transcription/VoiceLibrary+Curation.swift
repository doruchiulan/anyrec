import Foundation

/// How many prints a person keeps, and which. One print per confirmed call piled up
/// without limit, and a person is matched by their nearest print, so every extra print was
/// one more chance of a wrong match while near-copies from the same headset added nothing.
/// A person keeps at most `maximumPrints`: a print almost the same as one they have
/// replaces it only when made from more speech, and when there are too many the most
/// redundant one is set aside — never the person's best. Set-aside prints are kept
/// (`Person.retired`), not matched, so the owner can bring one back.
extension VoiceLibrary {
    public static let maximumPrints = 6
    /// Two prints this alike are one condition heard twice.
    public static let duplicatePrint: Float = 0.92
    public static let maximumRetired = 10
    /// What a print made before its speech was counted is taken to stand for.
    static let assumedSeconds: TimeInterval = 30

    /// What `Person.admit` did with a print.
    public enum Admitted: Equatable, Sendable {
        case added
        /// It replaced an almost identical print made from less speech.
        case replaced
        /// Almost identical to one the person has, and no better: not added.
        case duplicate
    }

    /// Puts a set-aside print of `name`'s back; if that makes too many, the weakest other
    /// print is set aside in its place.
    public mutating func bringBack(retired index: Int, of name: String) {
        guard let person = people.firstIndex(where: { $0.name == name }), people[person].retired.indices.contains(index) else { return }
        people[person].bringBack(index)
    }
}

extension VoiceLibrary.Person {
    /// How much a print is worth, 0 to 1: half how much speech it was made from (two
    /// minutes or more counts fully), half how well it agrees with the person's other prints.
    public func quality(ofPrint index: Int) -> Float {
        guard prints.indices.contains(index) else { return 0 }
        let seconds = origin(ofPrint: index)?.seconds ?? VoiceLibrary.assumedSeconds
        let speech = Float(min(seconds, 120) / 120)
        let others = prints.indices.filter { $0 != index }.map { VoiceLibrary.similarity(prints[$0], prints[index]) }
        let agreement = others.isEmpty ? 1 : max(0, min(1, others.reduce(0, +) / Float(others.count)))
        return 0.5 * speech + 0.5 * agreement
    }

    /// How close a print is to the nearest of the person's others: near one means it adds
    /// nothing they do not have.
    func redundancy(ofPrint index: Int) -> Float {
        prints.indices.filter { $0 != index }.map { VoiceLibrary.similarity(prints[$0], prints[index]) }.max() ?? 0
    }

    /// Every print joins a person through here.
    @discardableResult
    mutating func admit(_ print: Voiceprint, origin: VoiceLibrary.PrintOrigin?) -> VoiceLibrary.Admitted {
        guard !prints.contains(print) else { return .duplicate }
        let near = prints.indices.max { VoiceLibrary.similarity(prints[$0], print) < VoiceLibrary.similarity(prints[$1], print) }
        if let near, VoiceLibrary.similarity(prints[near], print) >= VoiceLibrary.duplicatePrint {
            let newer = origin?.seconds ?? VoiceLibrary.assumedSeconds
            let older = self.origin(ofPrint: near)?.seconds ?? VoiceLibrary.assumedSeconds
            guard newer > older else { return .duplicate }
            retire(near)
            add(print, origin: origin)
            return .replaced
        }
        add(print, origin: origin)
        trim()
        return .added
    }

    /// Sets aside prints until there are `maximumPrints`: the most redundant first, weighed
    /// against quality, never the best one and never `keeping`.
    mutating func trim(keeping kept: Voiceprint? = nil) {
        while prints.count > VoiceLibrary.maximumPrints {
            guard let best = prints.indices.max(by: { quality(ofPrint: $0) < quality(ofPrint: $1) }) else { return }
            let candidates = prints.indices.filter { $0 != best && prints[$0] != kept }
            guard let drop = candidates.max(by: {
                redundancy(ofPrint: $0) - 0.5 * quality(ofPrint: $0) < redundancy(ofPrint: $1) - 0.5 * quality(ofPrint: $1)
            }) else { return }
            retire(drop)
        }
    }

    mutating func retire(_ index: Int) {
        let origin = origin(ofPrint: index)
        retired.append(prints[index])
        retiredOrigins.append(origin)
        removePrint(at: index)
        while retired.count > VoiceLibrary.maximumRetired {
            retired.removeFirst()
            if !retiredOrigins.isEmpty { retiredOrigins.removeFirst() }
        }
    }

    mutating func bringBack(_ index: Int) {
        let print = retired.remove(at: index)
        let origin = retiredOrigins.indices.contains(index) ? retiredOrigins.remove(at: index) : nil
        add(print, origin: origin)
        trim(keeping: print)
    }

    /// Where set-aside print `index` came from.
    public func origin(ofRetired index: Int) -> VoiceLibrary.PrintOrigin? {
        retiredOrigins.indices.contains(index) ? retiredOrigins[index] : nil
    }
}
