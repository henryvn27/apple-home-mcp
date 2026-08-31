import Foundation

enum ValueValidator {
    private static let writableFormats: Set<String> = [
        "bool", "int", "uint8", "uint16", "uint32", "uint64", "float", "string",
    ]

    static func supportsAgentWrite(format: String?) -> Bool {
        guard let format else { return false }
        return writableFormats.contains(format)
    }

    static func supportsAgentRead(format: String?) -> Bool {
        format != "data" && format != "tlv8"
    }

    static func validate(_ value: JSONValue, metadata: CharacteristicMetadataRecord?) throws -> Any {
        guard value != .null else {
            throw BridgeError("invalid_value", "characteristic values cannot be null")
        }
        guard let metadata, let format = metadata.format else {
            throw BridgeError("unsupported_value", "characteristic write metadata is unavailable")
        }

        guard supportsAgentWrite(format: format) else {
            throw BridgeError(
                "unsupported_value",
                "HomeKit array, dictionary, data, TLV8, and private formats cannot be written"
            )
        }

        switch format {
        case "bool":
            guard case let .bool(boolean) = value else { throw typeError(format) }
            return NSNumber(value: boolean)
        case "int":
            let number = try finiteNumber(value, format: format)
            guard number.rounded() == number else { throw typeError(format) }
            guard Double(Int32.min) <= number, number <= Double(Int32.max) else {
                throw BridgeError("invalid_value", "value is outside the HomeKit int range")
            }
            try validateNumber(number, metadata: metadata)
            return NSNumber(value: Int32(number))
        case "uint8", "uint16", "uint32", "uint64":
            let number = try finiteNumber(value, format: format)
            guard number.rounded() == number else { throw typeError(format) }
            let maximum: Double
            switch format {
            case "uint8": maximum = Double(UInt8.max)
            case "uint16": maximum = Double(UInt16.max)
            case "uint32": maximum = Double(UInt32.max)
            default: maximum = 9_007_199_254_740_991
            }
            guard 0...maximum ~= number else {
                throw BridgeError("invalid_value", "value is outside the safe HomeKit \(format) range")
            }
            try validateNumber(number, metadata: metadata)
            switch format {
            case "uint8": return NSNumber(value: UInt8(number))
            case "uint16": return NSNumber(value: UInt16(number))
            case "uint32": return NSNumber(value: UInt32(number))
            default: return NSNumber(value: UInt64(number))
            }
        case "float":
            let number = try finiteNumber(value, format: format)
            guard Float(number).isFinite else {
                throw BridgeError("invalid_value", "value is outside the HomeKit float range")
            }
            try validateNumber(number, metadata: metadata)
            return NSNumber(value: Float(number))
        case "string":
            guard case let .string(string) = value else { throw typeError(format) }
            if let maximumLength = metadata.maximumLength, string.utf8.count > maximumLength {
                throw BridgeError("invalid_value", "string exceeds the characteristic maximum length")
            }
            return string
        default: preconditionFailure("writable HomeKit format was not validated")
        }
    }

    private static func finiteNumber(_ value: JSONValue, format: String) throws -> Double {
        guard case let .number(number) = value, number.isFinite else { throw typeError(format) }
        return number
    }

    private static func validateNumber(
        _ value: Double,
        metadata: CharacteristicMetadataRecord
    ) throws {
        let metadataNumbers = [
            metadata.minimumValue,
            metadata.maximumValue,
            metadata.stepValue,
        ].compactMap { $0 } + (metadata.validValues ?? [])
        guard metadataNumbers.allSatisfy(\.isFinite),
              metadata.minimumValue.map({ minimum in
                  metadata.maximumValue.map { minimum <= $0 } ?? true
              }) ?? true,
              metadata.stepValue.map({ $0 > 0 }) ?? true else {
            throw BridgeError("unsupported_value", "characteristic numeric metadata is invalid")
        }
        if let minimum = metadata.minimumValue, value < minimum {
            throw BridgeError("invalid_value", "value is below the characteristic minimum")
        }
        if let maximum = metadata.maximumValue, value > maximum {
            throw BridgeError("invalid_value", "value is above the characteristic maximum")
        }
        if let validValues = metadata.validValues,
           !validValues.contains(where: { approximatelyEqual($0, value) }) {
            throw BridgeError("invalid_value", "value is not one of the characteristic enum values")
        }
        if let step = metadata.stepValue {
            let origin = metadata.minimumValue ?? 0
            let steps = (value - origin) / step
            if !approximatelyEqual(steps, steps.rounded()) {
                throw BridgeError("invalid_value", "value does not match the characteristic step")
            }
        }
    }

    private static func approximatelyEqual(_ left: Double, _ right: Double) -> Bool {
        abs(left - right) <= max(1, max(abs(left), abs(right))) * 1e-9
    }

    private static func typeError(_ format: String) -> BridgeError {
        BridgeError("invalid_value", "value does not match HomeKit format \(format)")
    }
}
