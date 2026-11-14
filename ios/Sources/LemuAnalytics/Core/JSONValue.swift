import Foundation

/// A JSON value. Everything the SDK queues or sends is converted to this first,
/// so a value the brand passes that JSON can't hold never reaches the encoder.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    // MARK: Accessors (used by the SDK and its tests)

    subscript(key: String) -> JSONValue? {
        if case let .object(dict) = self { return dict[key] }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case let .double(value): return value
        case let .int(value): return Double(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    // MARK: Converting values from the brand's code

    private static let maxDepth = 16

    /// Converts `[String: Any]` from the host app. Keys whose values JSON can't
    /// represent (NaN, infinity, nesting deeper than 16) are left out.
    static func properties(_ dictionary: [String: Any]?) -> [String: JSONValue] {
        guard let dictionary = dictionary else { return [:] }
        var result: [String: JSONValue] = [:]
        for (key, value) in dictionary {
            if let converted = wrap(value, depth: 1) {
                result[key] = converted
            }
        }
        return result
    }

    /// Returns nil for a value that can't be represented.
    static func wrap(_ value: Any?, depth: Int = 0) -> JSONValue? {
        guard depth <= maxDepth else { return nil }
        guard let value = value else { return .null }

        // `Any` can hold an Optional; unwrap it.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return .null }
            return wrap(child.value, depth: depth)
        }

        switch value {
        case let json as JSONValue:
            return json
        case let string as String:
            return .string(string)
        case let substring as Substring:
            return .string(String(substring))
        case is NSNull:
            return .null
        case let date as Date:
            return .string(ISO8601.string(from: date))
        case let url as URL:
            return .string(url.absoluteString)
        case let uuid as UUID:
            return .string(uuid.uuidString)
        case let content as LemuContent:
            return content.jsonValue
        case let decimal as Decimal:
            let number = NSDecimalNumber(decimal: decimal).doubleValue
            return number.isFinite ? .double(number) : nil
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if CFNumberIsFloatType(number) {
                let double = number.doubleValue
                return double.isFinite ? .double(double) : nil
            }
            return .int(number.int64Value)
        case let array as [Any]:
            return .array(array.compactMap { wrap($0, depth: depth + 1) })
        case let dictionary as [String: Any]:
            var result: [String: JSONValue] = [:]
            for (key, item) in dictionary {
                if let converted = wrap(item, depth: depth + 1) { result[key] = converted }
            }
            return .object(result)
        case let dictionary as [AnyHashable: Any]:
            var result: [String: JSONValue] = [:]
            for (key, item) in dictionary {
                if let converted = wrap(item, depth: depth + 1) { result["\(key.base)"] = converted }
            }
            return .object(result)
        default:
            return .string(String(describing: value))
        }
    }
}

enum JSON {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    static func encode<T: Encodable>(_ value: T) -> Data? {
        // JSONEncoder is safe to share between threads, but every use here runs
        // on the SDK's serial queue anyway.
        return try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum ISO8601 {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// `2026-11-14T10:00:01.123Z`
    static func string(from date: Date) -> String {
        return formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        return formatter.date(from: string)
    }
}
