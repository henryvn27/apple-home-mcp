import CoreFoundation
import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    static func fromFoundation(_ value: Any?) throws -> JSONValue {
        guard let value else { return .null }
        switch value {
        case is NSNull: return .null
        case let value as NSNumber:
            return CFGetTypeID(value) == CFBooleanGetTypeID()
                ? .bool(value.boolValue)
                : .number(value.doubleValue)
        case let value as String: return .string(value)
        case let value as [Any]: return .array(try value.map(fromFoundation))
        case let value as [String: Any]:
            return .object(try value.mapValues(fromFoundation))
        default: throw BridgeError("unsupported_value", "HomeKit returned a non-JSON value")
        }
    }

    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return NSNumber(value: value)
        case let .number(value): return NSNumber(value: value)
        case let .string(value): return value
        case let .array(value): return value.map(\.foundationValue)
        case let .object(value): return value.mapValues(\.foundationValue)
        }
    }
}

extension Encodable {
    func jsonValue() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
    }
}
