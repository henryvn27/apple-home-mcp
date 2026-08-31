import Foundation

struct BridgeError: Error, Equatable {
    let code: String
    let message: String

    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

struct CharacteristicMetadataRecord: Codable, Equatable, Sendable {
    var format: String?
    var units: String?
    var minimumValue: Double?
    var maximumValue: Double?
    var stepValue: Double?
    var maximumLength: Int?
    var validValues: [Double]?
    var manufacturerDescription: String?
}

struct CharacteristicRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let type: String
    let name: String
    let readable: Bool
    let writable: Bool
    let metadata: CharacteristicMetadataRecord?
    let requiresHumanApproval: Bool
}

struct ServiceRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let type: String
    let name: String
    let requiresHumanApproval: Bool
    let characteristics: [CharacteristicRecord]
}

struct AccessoryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let roomID: String?
    let roomName: String?
    let reachable: Bool
    let services: [ServiceRecord]
}

struct RoomRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct ZoneRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let roomIDs: [String]
}

struct HomeRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let rooms: [RoomRecord]
    let zones: [ZoneRecord]
    let accessories: [AccessoryRecord]
}

struct SceneRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let homeID: String
    let name: String
    let type: String
    let requiresHumanApproval: Bool
}

struct CharacteristicReference: Codable, Equatable, Sendable {
    let homeID: String
    let accessoryID: String
    let serviceID: String
    let characteristicID: String
}

struct SceneReference: Codable, Equatable, Sendable {
    let homeID: String
    let sceneID: String
}

struct StoreStatus: Codable, Equatable, Sendable {
    let loaded: Bool
    let authorizationStatus: String
    let homeCount: Int
}

enum UniqueLookup {
    static func one<T>(_ values: [T], kind: String) throws -> T {
        guard values.count == 1 else {
            throw values.isEmpty
                ? BridgeError("not_found", "\(kind) UUID was not found in the current Home graph")
                : BridgeError("ambiguous_identifier", "\(kind) UUID was duplicated in the current Home graph")
        }
        return values[0]
    }
}

protocol NamedRecord { var name: String { get } }
extension RoomRecord: NamedRecord {}
extension ZoneRecord: NamedRecord {}
extension HomeRecord: NamedRecord {}
extension AccessoryRecord: NamedRecord {}
extension ServiceRecord: NamedRecord {}
extension CharacteristicRecord: NamedRecord {}
extension SceneRecord: NamedRecord {}

struct BridgeRequest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let token: String
    let operation: String
    let arguments: [String: JSONValue]
}

struct BridgeResponse: Codable, Equatable, Sendable {
    struct ErrorBody: Codable, Equatable, Sendable {
        let code: String
        let message: String
    }

    let ok: Bool
    let result: JSONValue?
    let error: ErrorBody?

    static func success(_ result: JSONValue) -> BridgeResponse {
        BridgeResponse(ok: true, result: result, error: nil)
    }

    static func failure(_ error: BridgeError) -> BridgeResponse {
        BridgeResponse(
            ok: false,
            result: nil,
            error: ErrorBody(code: error.code, message: String(error.message.prefix(500)))
        )
    }
}
