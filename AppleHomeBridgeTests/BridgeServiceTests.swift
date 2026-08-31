import Foundation
import HomeKit
import XCTest
@testable import AppleHomeBridge

@MainActor
final class BridgeServiceTests: XCTestCase {
    private let token = "0123456789abcdef0123456789abcdef"

    func testStatusUsesAuthenticatedSingleLineResponse() async throws {
        let response = await service().handle(line: request(operation: "status"))
        XCTAssertEqual(response.last, 0x0A)
        XCTAssertEqual(response.filter { $0 == 0x0A }.count, 1)
        let body = try decode(response)
        XCTAssertTrue(body.ok)
        XCTAssertEqual(body.result?.object?["authorizationStatus"], .string("authorized"))
    }

    func testRejectsBadTokenSchemaMalformedJSONAndUnknownArguments() async throws {
        let badToken = try decode(await service().handle(line: request(operation: "status", token: "wrong")))
        let badSchema = try decode(await service().handle(line: request(operation: "status", schema: 2)))
        let malformed = try decode(await service().handle(line: Data("{".utf8)))
        let extraArguments = try decode(await service().handle(
            line: request(operation: "status", arguments: ["extra": .bool(true)])
        ))
        XCTAssertEqual(badToken.error?.code, "not_authenticated")
        XCTAssertEqual(badSchema.error?.code, "unsupported_schema")
        XCTAssertEqual(malformed.error?.code, "invalid_request")
        XCTAssertEqual(extraArguments.error?.code, "invalid_arguments")
    }

    func testRejectsUnknownEnvelopeFields() async throws {
        let data = Data(
            #"{"schemaVersion":1,"token":"0123456789abcdef0123456789abcdef","operation":"status","arguments":{},"extra":true}"#.utf8
        )
        let response = try decode(await service().handle(line: data))
        XCTAssertEqual(response.error?.code, "invalid_request")
    }

    func testReadAlwaysCallsStore() async throws {
        let store = MockHomeStore()
        let service = BridgeService(store: store, token: token)
        let first = try decode(await service.handle(line: request(operation: "read_characteristic", arguments: TestIDs.characteristicArguments)))
        store.readValue = .number(73)
        let second = try decode(await service.handle(line: request(operation: "read_characteristic", arguments: TestIDs.characteristicArguments)))
        XCTAssertEqual(store.readCount, 2)
        XCTAssertEqual(first.result?.object?["value"], .number(72))
        XCTAssertEqual(second.result?.object?["value"], .number(73))
    }

    func testWritesRequireConfirmationAndHighRiskFailsClosed() async throws {
        let store = MockHomeStore()
        let service = BridgeService(store: store, token: token)
        var arguments = TestIDs.characteristicArguments
        arguments["value"] = .bool(true)
        arguments["confirm"] = .bool(false)
        let unconfirmed = try decode(await service.handle(
            line: request(operation: "write_characteristic", arguments: arguments)
        ))
        XCTAssertEqual(unconfirmed.error?.code, "confirmation_required")
        arguments["confirm"] = .bool(true)
        store.highRiskCharacteristic = true
        let highRisk = try decode(await service.handle(
            line: request(operation: "write_characteristic", arguments: arguments)
        ))
        XCTAssertEqual(highRisk.error?.code, "human_approval_required")
        XCTAssertTrue(store.writes.isEmpty)
        store.highRiskCharacteristic = false
        let allowed = try decode(await service.handle(
            line: request(operation: "write_characteristic", arguments: arguments)
        ))
        XCTAssertTrue(allowed.ok)
        XCTAssertEqual(store.writes.count, 1)
    }

    func testScenesFilterRequireConfirmationAndFailClosed() async throws {
        let store = MockHomeStore()
        store.sceneRecords = [
            SceneRecord(id: TestIDs.scene, homeID: TestIDs.home, name: "Good Night", type: "user", requiresHumanApproval: false),
            SceneRecord(id: UUID().uuidString.lowercased(), homeID: UUID().uuidString.lowercased(), name: "Away", type: "user", requiresHumanApproval: false),
        ]
        let service = BridgeService(store: store, token: token)
        let listed = try decode(await service.handle(line: request(operation: "list_scenes", arguments: ["home_id": .string(TestIDs.home)])))
        XCTAssertEqual(listed.result?.object?["scenes"]?.array?.count, 1)
        let arguments: [String: JSONValue] = [
            "home_id": .string(TestIDs.home),
            "scene_id": .string(TestIDs.scene),
            "confirm": .bool(true),
        ]
        store.highRiskScene = true
        let highRisk = try decode(await service.handle(
            line: request(operation: "run_scene", arguments: arguments)
        ))
        XCTAssertEqual(highRisk.error?.code, "human_approval_required")
        XCTAssertTrue(store.executedScenes.isEmpty)
        store.highRiskScene = false
        let allowed = try decode(await service.handle(
            line: request(operation: "run_scene", arguments: arguments)
        ))
        XCTAssertTrue(allowed.ok)
        XCTAssertEqual(store.executedScenes.count, 1)
    }

    func testInventoryReturnsMockGraphWithoutUsingHomeKit() async throws {
        let store = MockHomeStore()
        store.homes = [HomeRecord(id: TestIDs.home, name: "Home", rooms: [], zones: [], accessories: [])]
        let response = try decode(await BridgeService(store: store, token: token).handle(line: request(operation: "inventory")))
        XCTAssertEqual(response.result?.object?["homes"]?.array?.count, 1)
    }

    func testOversizedResponseFailsClosedWithinProtocolLimit() async throws {
        let store = MockHomeStore()
        store.homes = [HomeRecord(
            id: TestIDs.home,
            name: String(repeating: "h", count: BridgeService.maximumMessageBytes),
            rooms: [],
            zones: [],
            accessories: []
        )]
        let response = await BridgeService(store: store, token: token)
            .handle(line: request(operation: "inventory"))
        XCTAssertLessThanOrEqual(response.count, BridgeService.maximumMessageBytes)
        XCTAssertEqual(try decode(response).error?.code, "response_too_large")
    }

    func testGraphLookupAndSafetyPolicyFailClosed() throws {
        XCTAssertThrowsError(try UniqueLookup.one([Int](), kind: "home")) { error in
            XCTAssertEqual((error as? BridgeError)?.code, "not_found")
        }
        XCTAssertThrowsError(try UniqueLookup.one([1, 2], kind: "home")) { error in
            XCTAssertEqual((error as? BridgeError)?.code, "ambiguous_identifier")
        }
        XCTAssertTrue(HomeSafetyPolicy.requiresHumanApproval(
            serviceType: HMServiceTypeLockMechanism,
            serviceName: "Lock",
            characteristicTypes: []
        ))
        XCTAssertTrue(HomeSafetyPolicy.requiresHumanApproval(
            serviceType: "vendor-service",
            serviceName: "Emergency siren",
            characteristicTypes: []
        ))
        XCTAssertFalse(HomeSafetyPolicy.requiresHumanApproval(
            serviceType: HMServiceTypeLightbulb,
            serviceName: "Desk lamp",
            characteristicTypes: []
        ))
    }

    private func service() -> BridgeService {
        BridgeService(store: MockHomeStore(), token: token)
    }

    private func request(
        operation: String,
        token: String? = nil,
        schema: Int = 1,
        arguments: [String: JSONValue] = [:]
    ) -> Data {
        try! JSONEncoder().encode(BridgeRequest(
            schemaVersion: schema,
            token: token ?? self.token,
            operation: operation,
            arguments: arguments
        ))
    }

    private func decode(_ framed: Data) throws -> BridgeResponse {
        try JSONDecoder().decode(BridgeResponse.self, from: framed.dropLast())
    }
}

private extension JSONValue {
    var object: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var array: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }
}
