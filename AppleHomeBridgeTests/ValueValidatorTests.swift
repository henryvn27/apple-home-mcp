import XCTest
@testable import AppleHomeBridge

final class ValueValidatorTests: XCTestCase {
    func testValidatesBooleanAndStringFormats() throws {
        XCTAssertNoThrow(try ValueValidator.validate(.bool(true), metadata: .init(format: "bool")))
        XCTAssertThrowsError(try ValueValidator.validate(.number(1), metadata: .init(format: "bool")))
        XCTAssertNoThrow(try ValueValidator.validate(.string("home"), metadata: .init(format: "string", maximumLength: 4)))
        XCTAssertThrowsError(try ValueValidator.validate(.string("homes"), metadata: .init(format: "string", maximumLength: 4)))
    }

    func testValidatesRangeStepAndEnums() throws {
        let metadata = CharacteristicMetadataRecord(
            format: "float",
            minimumValue: 10,
            maximumValue: 20,
            stepValue: 2,
            validValues: [10, 12, 14, 16, 18, 20]
        )
        XCTAssertNoThrow(try ValueValidator.validate(.number(14), metadata: metadata))
        XCTAssertThrowsError(try ValueValidator.validate(.number(13), metadata: metadata))
        XCTAssertThrowsError(try ValueValidator.validate(.number(22), metadata: metadata))
    }

    func testRejectsFractionalIntegerNullAndBinaryFormats() {
        XCTAssertThrowsError(try ValueValidator.validate(.number(1.5), metadata: .init(format: "int")))
        XCTAssertThrowsError(try ValueValidator.validate(.null, metadata: nil))
        XCTAssertThrowsError(try ValueValidator.validate(.string("AA=="), metadata: .init(format: "data")))
    }

    func testRejectsStructuredWritesAndMissingMetadata() {
        XCTAssertThrowsError(try ValueValidator.validate(.array([]), metadata: .init(format: "array")))
        XCTAssertThrowsError(try ValueValidator.validate(.object([:]), metadata: .init(format: "dictionary")))
        XCTAssertThrowsError(try ValueValidator.validate(.bool(true), metadata: nil))
        XCTAssertFalse(ValueValidator.supportsAgentWrite(format: "array"))
        XCTAssertFalse(ValueValidator.supportsAgentWrite(format: "dictionary"))
        XCTAssertFalse(ValueValidator.supportsAgentWrite(format: "data"))
        XCTAssertFalse(ValueValidator.supportsAgentWrite(format: "tlv8"))
        XCTAssertTrue(ValueValidator.supportsAgentWrite(format: "bool"))
        XCTAssertFalse(ValueValidator.supportsAgentRead(format: "data"))
        XCTAssertFalse(ValueValidator.supportsAgentRead(format: "tlv8"))
    }

    func testEnforcesIntrinsicNumericRanges() {
        XCTAssertThrowsError(try ValueValidator.validate(.number(-1), metadata: .init(format: "uint8")))
        XCTAssertThrowsError(try ValueValidator.validate(.number(256), metadata: .init(format: "uint8")))
        XCTAssertThrowsError(try ValueValidator.validate(.number(Double(Int32.max) + 1), metadata: .init(format: "int")))
        XCTAssertThrowsError(try ValueValidator.validate(.number(9_007_199_254_740_992), metadata: .init(format: "uint64")))
    }

    func testRejectsInvalidNumericMetadata() {
        XCTAssertThrowsError(try ValueValidator.validate(
            .number(5),
            metadata: .init(format: "float", minimumValue: 10, maximumValue: 1)
        ))
        XCTAssertThrowsError(try ValueValidator.validate(
            .number(5),
            metadata: .init(format: "float", stepValue: 0)
        ))
        XCTAssertThrowsError(try ValueValidator.validate(
            .number(5),
            metadata: .init(format: "float", validValues: [.infinity])
        ))
    }
}

private extension CharacteristicMetadataRecord {
    init(
        format: String,
        minimumValue: Double? = nil,
        maximumValue: Double? = nil,
        stepValue: Double? = nil,
        maximumLength: Int? = nil,
        validValues: [Double]? = nil
    ) {
        self.init(
            format: format,
            units: nil,
            minimumValue: minimumValue,
            maximumValue: maximumValue,
            stepValue: stepValue,
            maximumLength: maximumLength,
            validValues: validValues,
            manufacturerDescription: nil
        )
    }
}
