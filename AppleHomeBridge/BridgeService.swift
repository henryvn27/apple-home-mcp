import Foundation

@MainActor
final class BridgeService {
    static let schemaVersion = 1
    nonisolated static let maximumMessageBytes = 1_048_576

    private let store: HomeStore
    private let token: String

    init(store: HomeStore, token: String) {
        self.store = store
        self.token = token
    }

    func handle(line: Data) async -> Data {
        let response: BridgeResponse
        do {
            guard !line.isEmpty, line.count < Self.maximumMessageBytes else {
                throw BridgeError("invalid_request", "request must contain at most 1 MiB")
            }
            let request: BridgeRequest
            do {
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      Set(object.keys) == ["schemaVersion", "token", "operation", "arguments"] else {
                    throw BridgeError("invalid_request", "request fields do not match the protocol contract")
                }
                request = try JSONDecoder().decode(BridgeRequest.self, from: line)
            }
            catch let error as BridgeError { throw error }
            catch { throw BridgeError("invalid_request", "request must be one valid UTF-8 JSON object") }
            guard request.schemaVersion == Self.schemaVersion else {
                throw BridgeError("unsupported_schema", "request schema version is not supported")
            }
            guard 32...512 ~= request.token.utf8.count,
                  constantTimeEqual(request.token, token) else {
                throw BridgeError("not_authenticated", "bridge token is invalid")
            }
            response = .success(try await perform(request))
        } catch let error as BridgeError {
            response = .failure(error)
        } catch {
            response = .failure(BridgeError("internal_error", "Apple Home Bridge could not complete the request"))
        }

        var data = (try? JSONEncoder().encode(response)) ?? Data(
            #"{"ok":false,"error":{"code":"internal_error","message":"response encoding failed"}}"#.utf8
        )
        if data.count >= Self.maximumMessageBytes {
            data = (try? JSONEncoder().encode(BridgeResponse.failure(BridgeError(
                "response_too_large",
                "response exceeded the 1 MiB protocol limit"
            )))) ?? Data(
                #"{"ok":false,"error":{"code":"internal_error","message":"response encoding failed"}}"#.utf8
            )
        }
        data.append(0x0A)
        return data
    }

    private func perform(_ request: BridgeRequest) async throws -> JSONValue {
        switch request.operation {
        case "status":
            try requireEmpty(request.arguments)
            var result = try store.status.jsonValue().objectValue
            result["appVersion"] = .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")
            return .object(result)
        case "inventory":
            try requireEmpty(request.arguments)
            return .object(["homes": try store.inventory().jsonValue()])
        case "read_characteristic":
            let reference = try characteristicReference(request.arguments, includesValue: false)
            return .object(["value": try await store.read(reference)])
        case "write_characteristic":
            let reference = try characteristicReference(request.arguments, includesValue: true)
            try requireConfirmation(request.arguments)
            if try store.characteristicRequiresHumanApproval(reference) {
                throw BridgeError("human_approval_required", "this high-risk Home control must be approved in the app")
            }
            guard let value = request.arguments["value"] else {
                throw BridgeError("invalid_arguments", "value is required")
            }
            try await store.write(reference, value: value)
            return .object(["written": .bool(true)])
        case "list_scenes":
            let unknown = Set(request.arguments.keys).subtracting(["home_id"])
            guard unknown.isEmpty else { throw invalidArguments() }
            let homeID = try optionalUUID(request.arguments["home_id"], name: "home_id")
            let scenes = try store.scenes().filter { homeID == nil || $0.homeID == homeID }
            return .object(["scenes": try scenes.jsonValue()])
        case "run_scene":
            try requireKeys(request.arguments, exactly: ["home_id", "scene_id", "confirm"])
            try requireConfirmation(request.arguments)
            let reference = SceneReference(
                homeID: try requiredUUID(request.arguments["home_id"], name: "home_id"),
                sceneID: try requiredUUID(request.arguments["scene_id"], name: "scene_id")
            )
            if try store.sceneRequiresHumanApproval(reference) {
                throw BridgeError("human_approval_required", "this high-risk scene must be approved in the app")
            }
            try await store.runScene(reference)
            return .object(["executed": .bool(true)])
        default:
            throw BridgeError("unsupported_operation", "operation is not supported")
        }
    }

    private func characteristicReference(
        _ arguments: [String: JSONValue],
        includesValue: Bool
    ) throws -> CharacteristicReference {
        var keys: Set<String> = ["home_id", "accessory_id", "service_id", "characteristic_id"]
        if includesValue { keys.formUnion(["value", "confirm"]) }
        try requireKeys(arguments, exactly: keys)
        return CharacteristicReference(
            homeID: try requiredUUID(arguments["home_id"], name: "home_id"),
            accessoryID: try requiredUUID(arguments["accessory_id"], name: "accessory_id"),
            serviceID: try requiredUUID(arguments["service_id"], name: "service_id"),
            characteristicID: try requiredUUID(arguments["characteristic_id"], name: "characteristic_id")
        )
    }

    private func requireConfirmation(_ arguments: [String: JSONValue]) throws {
        guard arguments["confirm"] == .bool(true) else {
            throw BridgeError("confirmation_required", "confirm=true is required for physical Home changes")
        }
    }

    private func requiredUUID(_ value: JSONValue?, name: String) throws -> String {
        guard case let .string(raw) = value, let uuid = UUID(uuidString: raw) else {
            throw BridgeError("invalid_arguments", "\(name) must be a UUID")
        }
        return uuid.uuidString.lowercased()
    }

    private func optionalUUID(_ value: JSONValue?, name: String) throws -> String? {
        guard let value else { return nil }
        return try requiredUUID(value, name: name)
    }

    private func requireEmpty(_ arguments: [String: JSONValue]) throws {
        guard arguments.isEmpty else { throw invalidArguments() }
    }

    private func requireKeys(_ arguments: [String: JSONValue], exactly keys: Set<String>) throws {
        guard Set(arguments.keys) == keys else { throw invalidArguments() }
    }

    private func invalidArguments() -> BridgeError {
        BridgeError("invalid_arguments", "arguments do not match the operation contract")
    }

    private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let lhs = Array(left.utf8)
        let rhs = Array(right.utf8)
        var difference = lhs.count ^ rhs.count
        for index in 0..<max(lhs.count, rhs.count) {
            let leftByte = index < lhs.count ? lhs[index] : 0
            let rightByte = index < rhs.count ? rhs[index] : 0
            difference |= Int(leftByte ^ rightByte)
        }
        return difference == 0
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue] {
        get throws {
            guard case let .object(value) = self else {
                throw BridgeError("internal_error", "encoded object was invalid")
            }
            return value
        }
    }
}
