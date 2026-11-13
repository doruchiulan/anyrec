import AnyRecKit
import Foundation
import MCP

struct MCPArguments {
    let values: [String: Value]

    init(_ values: [String: Value], schema: Value) throws {
        let properties = schema.objectValue?["properties"]?.objectValue ?? [:]
        let required = schema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard Set(values.keys).isSubset(of: Set(properties.keys)), required.allSatisfy({ values[$0] != nil }) else {
            throw MeetingReadError.invalid("Missing required arguments or unknown argument names.")
        }
        for (name, value) in values { try Self.validate(value, name: name, schema: properties[name]!) }
        self.values = values
    }

    var offset: Int { values["offset"]?.intValue ?? 0 }
    func limit(_ fallback: Int) -> Int { values["limit"]?.intValue ?? fallback }
    func string(_ name: String) -> String? { values[name]?.stringValue }
    func number(_ name: String) -> Double? { values[name]?.doubleValue ?? values[name]?.intValue.map(Double.init) }

    func required(_ name: String) throws -> String {
        guard let value = string(name) else { throw MeetingReadError.invalid("Missing \(name).") }
        return value
    }

    func filter(title: Bool) throws -> MeetingFilter {
        let after = try date("after"), before = try date("before")
        guard after == nil || before == nil || after! < before! else {
            throw MeetingReadError.invalid("after must be earlier than before.")
        }
        return MeetingFilter(query: title ? string("query") : nil, participant: string("participant"), after: after, before: before)
    }

    private func date(_ name: String) throws -> Date? {
        guard let text = string(name) else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        guard let date = formatter.date(from: text) else {
            throw MeetingReadError.invalid("\(name) must be an ISO 8601 timestamp with timezone.")
        }
        return date
    }

    private static func validate(_ value: Value, name: String, schema: Value) throws {
        let rule = schema.objectValue ?? [:]
        switch rule["type"]?.stringValue {
        case "string":
            guard let text = value.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 500, rule["enum"]?.arrayValue?.contains(value) ?? true else {
                throw MeetingReadError.invalid("Invalid string value for \(name).")
            }
        case "integer":
            guard let number = value.intValue, number >= (rule["minimum"]?.intValue ?? 0),
                  number <= (rule["maximum"]?.intValue ?? Int.max) else {
                throw MeetingReadError.invalid("Invalid integer value for \(name).")
            }
        case "number":
            guard let number = value.doubleValue ?? value.intValue.map(Double.init), number.isFinite, number >= 0 else {
                throw MeetingReadError.invalid("\(name) must be nonnegative seconds.")
            }
        default: throw MeetingReadError.invalid("Unsupported argument \(name).")
        }
    }
}
