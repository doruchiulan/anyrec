import Foundation

public enum DurationError: Error, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self {
        case .malformed(let text):
            "Cannot read \"\(text)\" as a duration. Use forms like 90s, 45m, 1h or 1h30m."
        }
    }
}

public enum DurationSpec {
    private static let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3_600]

    /// Parses `90`, `90s`, `45m`, `1h`, `1h30m` into seconds. A bare number means seconds.
    public static func parse(_ text: String) throws -> TimeInterval {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { throw DurationError.malformed(text) }

        if let bare = TimeInterval(trimmed) {
            guard bare > 0 else { throw DurationError.malformed(text) }
            return bare
        }

        var total: TimeInterval = 0
        var digits = ""
        for character in trimmed {
            if character.isNumber {
                digits.append(character)
            } else if let unit = units[character], let value = TimeInterval(digits) {
                total += value * unit
                digits = ""
            } else {
                throw DurationError.malformed(text)
            }
        }

        guard digits.isEmpty, total > 0 else { throw DurationError.malformed(text) }
        return total
    }
}
