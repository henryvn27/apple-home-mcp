import Foundation
@testable import AppleHomeBridge

@MainActor
final class MockHomeStore: HomeStore {
    var status = StoreStatus(loaded: true, authorizationStatus: "authorized", homeCount: 1)
    var homes: [HomeRecord] = []
    var sceneRecords: [SceneRecord] = []
    var readValue: JSONValue = .number(72)
    var highRiskCharacteristic = false
    var highRiskScene = false
    var readCount = 0
    var writes: [(CharacteristicReference, JSONValue)] = []
    var executedScenes: [SceneReference] = []

    func inventory() throws -> [HomeRecord] { homes }

    func read(_ reference: CharacteristicReference) async throws -> JSONValue {
        readCount += 1
        return readValue
    }

    func write(_ reference: CharacteristicReference, value: JSONValue) async throws {
        writes.append((reference, value))
    }

    func scenes() throws -> [SceneRecord] { sceneRecords }

    func runScene(_ reference: SceneReference) async throws {
        executedScenes.append(reference)
    }

    func characteristicRequiresHumanApproval(_ reference: CharacteristicReference) throws -> Bool {
        highRiskCharacteristic
    }

    func sceneRequiresHumanApproval(_ reference: SceneReference) throws -> Bool { highRiskScene }
}

enum TestIDs {
    static let home = "00000000-0000-0000-0000-000000000001"
    static let accessory = "00000000-0000-0000-0000-000000000002"
    static let service = "00000000-0000-0000-0000-000000000003"
    static let characteristic = "00000000-0000-0000-0000-000000000004"
    static let scene = "00000000-0000-0000-0000-000000000005"

    static var characteristicArguments: [String: JSONValue] {
        [
            "home_id": .string(home),
            "accessory_id": .string(accessory),
            "service_id": .string(service),
            "characteristic_id": .string(characteristic),
        ]
    }
}
