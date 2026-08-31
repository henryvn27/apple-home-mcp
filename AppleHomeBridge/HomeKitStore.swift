import Foundation
import HomeKit

@MainActor
final class HomeKitStore: NSObject, HomeStore, @preconcurrency HMHomeManagerDelegate, ObservableObject {
    @Published private(set) var loaded = false
    private let manager: HMHomeManager

    override init() {
        manager = HMHomeManager()
        super.init()
        manager.delegate = self
    }

    var status: StoreStatus {
        StoreStatus(
            loaded: loaded,
            authorizationStatus: authorizationDescription,
            homeCount: manager.homes.count
        )
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        loaded = true
    }

    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        objectWillChange.send()
    }

    func inventory() throws -> [HomeRecord] {
        try requireReady()
        return manager.homes.map { home in
            HomeRecord(
                id: id(home.uniqueIdentifier),
                name: home.name,
                rooms: home.rooms.map { RoomRecord(id: id($0.uniqueIdentifier), name: $0.name) }
                    .sorted(by: namedBefore),
                zones: home.zones.map {
                    ZoneRecord(
                        id: id($0.uniqueIdentifier),
                        name: $0.name,
                        roomIDs: $0.rooms.map { id($0.uniqueIdentifier) }.sorted()
                    )
                }.sorted(by: namedBefore),
                accessories: home.accessories.map(accessoryRecord).sorted(by: namedBefore)
            )
        }.sorted(by: namedBefore)
    }

    func read(_ reference: CharacteristicReference) async throws -> JSONValue {
        let characteristic = try resolve(reference)
        guard characteristic.properties.contains(HMCharacteristicPropertyReadable),
              ValueValidator.supportsAgentRead(format: characteristic.metadata?.format) else {
            throw BridgeError("not_readable", "characteristic is not readable")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.readValue { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        return try JSONValue.fromFoundation(characteristic.value)
    }

    func write(_ reference: CharacteristicReference, value: JSONValue) async throws {
        let characteristic = try resolve(reference)
        guard characteristic.properties.contains(HMCharacteristicPropertyWritable) else {
            throw BridgeError("not_writable", "characteristic is not writable")
        }
        guard let service = characteristic.service else {
            throw BridgeError("not_found", "characteristic service is missing")
        }
        if serviceRequiresHumanApproval(service) {
            throw BridgeError("human_approval_required", "this high-risk Home control must be approved in the app")
        }
        let validated = try ValueValidator.validate(value, metadata: metadataRecord(characteristic.metadata))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(validated) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func scenes() throws -> [SceneRecord] {
        try requireReady()
        return manager.homes.flatMap { home in
            home.actionSets.map { actionSet in
                SceneRecord(
                    id: id(actionSet.uniqueIdentifier),
                    homeID: id(home.uniqueIdentifier),
                    name: actionSet.name,
                    type: actionSet.actionSetType,
                    requiresHumanApproval: actionSetRequiresHumanApproval(actionSet)
                )
            }
        }.sorted(by: namedBefore)
    }

    func runScene(_ reference: SceneReference) async throws {
        let (home, actionSet) = try resolve(reference)
        if actionSetRequiresHumanApproval(actionSet) {
            throw BridgeError("human_approval_required", "this high-risk scene must be approved in the app")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.executeActionSet(actionSet) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func characteristicRequiresHumanApproval(_ reference: CharacteristicReference) throws -> Bool {
        guard let service = try resolve(reference).service else {
            throw BridgeError("not_found", "characteristic service is missing")
        }
        return serviceRequiresHumanApproval(service)
    }

    func sceneRequiresHumanApproval(_ reference: SceneReference) throws -> Bool {
        actionSetRequiresHumanApproval(try resolve(reference).1)
    }

    private var authorizationDescription: String {
        let status = manager.authorizationStatus
        if status.contains(.authorized) { return "authorized" }
        if status.contains(.restricted) { return "restricted" }
        return "not_determined"
    }

    private func requireReady() throws {
        guard loaded else { throw BridgeError("not_ready", "HomeKit is still loading") }
        guard manager.authorizationStatus.contains(.authorized) else {
            throw BridgeError("not_authorized", "Home access is not authorized")
        }
    }

    private func accessoryRecord(_ accessory: HMAccessory) -> AccessoryRecord {
        AccessoryRecord(
            id: id(accessory.uniqueIdentifier),
            name: accessory.name,
            roomID: accessory.room.map { id($0.uniqueIdentifier) },
            roomName: accessory.room?.name,
            reachable: accessory.isReachable,
            services: accessory.services.map(serviceRecord).sorted(by: namedBefore)
        )
    }

    private func serviceRecord(_ service: HMService) -> ServiceRecord {
        let requiresHumanApproval = serviceRequiresHumanApproval(service)
        let characteristics = service.characteristics.compactMap { characteristic -> CharacteristicRecord? in
            guard !characteristic.properties.contains(HMCharacteristicPropertyHidden) else { return nil }
            let format = characteristic.metadata?.format
            let readable = characteristic.properties.contains(HMCharacteristicPropertyReadable)
                && ValueValidator.supportsAgentRead(format: format)
            let writable = characteristic.properties.contains(HMCharacteristicPropertyWritable)
                && ValueValidator.supportsAgentWrite(format: format)
            return CharacteristicRecord(
                id: id(characteristic.uniqueIdentifier),
                type: characteristic.characteristicType,
                name: characteristic.localizedDescription,
                readable: readable,
                writable: writable,
                metadata: metadataRecord(characteristic.metadata),
                requiresHumanApproval: requiresHumanApproval
            )
        }.sorted(by: namedBefore)
        return ServiceRecord(
            id: id(service.uniqueIdentifier),
            type: service.serviceType,
            name: service.name,
            requiresHumanApproval: requiresHumanApproval,
            characteristics: characteristics
        )
    }

    private func metadataRecord(_ metadata: HMCharacteristicMetadata?) -> CharacteristicMetadataRecord? {
        guard let metadata else { return nil }
        return CharacteristicMetadataRecord(
            format: metadata.format,
            units: metadata.units,
            minimumValue: metadata.minimumValue?.doubleValue,
            maximumValue: metadata.maximumValue?.doubleValue,
            stepValue: metadata.stepValue?.doubleValue,
            maximumLength: metadata.maxLength?.intValue,
            validValues: metadata.validValues?.map(\.doubleValue),
            manufacturerDescription: metadata.manufacturerDescription
        )
    }

    private func resolve(_ reference: CharacteristicReference) throws -> HMCharacteristic {
        try requireReady()
        let homes = manager.homes.filter { id($0.uniqueIdentifier) == reference.homeID }
        let home = try UniqueLookup.one(homes, kind: "home")
        let accessories = home.accessories.filter { id($0.uniqueIdentifier) == reference.accessoryID }
        let accessory = try UniqueLookup.one(accessories, kind: "accessory")
        let services = accessory.services.filter { id($0.uniqueIdentifier) == reference.serviceID }
        let service = try UniqueLookup.one(services, kind: "service")
        let characteristics = service.characteristics.filter {
            id($0.uniqueIdentifier) == reference.characteristicID
        }
        return try UniqueLookup.one(characteristics, kind: "characteristic")
    }

    private func resolve(_ reference: SceneReference) throws -> (HMHome, HMActionSet) {
        try requireReady()
        let homes = manager.homes.filter { id($0.uniqueIdentifier) == reference.homeID }
        let home = try UniqueLookup.one(homes, kind: "home")
        let scenes = home.actionSets.filter { id($0.uniqueIdentifier) == reference.sceneID }
        return (home, try UniqueLookup.one(scenes, kind: "scene"))
    }

    private func actionSetRequiresHumanApproval(_ actionSet: HMActionSet) -> Bool {
        actionSet.actions.contains { action in
            guard let write = action as? HMCharacteristicWriteAction<NSCopying>,
                  let service = write.characteristic.service else { return true }
            return serviceRequiresHumanApproval(service)
        }
    }

    private func serviceRequiresHumanApproval(_ service: HMService) -> Bool {
        HomeSafetyPolicy.requiresHumanApproval(
            serviceType: service.serviceType,
            serviceName: service.localizedDescription,
            characteristicTypes: service.characteristics.map(\.characteristicType)
        )
    }

    private func id(_ identifier: UUID) -> String { identifier.uuidString.lowercased() }

    private func namedBefore<T: NamedRecord>(_ left: T, _ right: T) -> Bool {
        if left.name.localizedCaseInsensitiveCompare(right.name) == .orderedSame {
            return String(describing: left).localizedCaseInsensitiveCompare(String(describing: right)) == .orderedAscending
        }
        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }
}

enum HomeSafetyPolicy {
    static func requiresHumanApproval(
        serviceType: String,
        serviceName: String,
        characteristicTypes: [String]
    ) -> Bool {
        let highRiskServiceTypes: Set<String> = [
            HMServiceTypeLockManagement,
            HMServiceTypeLockMechanism,
            HMServiceTypeGarageDoorOpener,
            HMServiceTypeSecuritySystem,
            HMServiceTypeCameraRTPStreamManagement,
            HMServiceTypeCameraControl,
            HMServiceTypeDoorbell,
            HMServiceTypeDoor,
            HMServiceTypeWindow,
            HMServiceTypeWindowCovering,
            HMServiceTypeSmokeSensor,
            HMServiceTypeCarbonDioxideSensor,
            HMServiceTypeCarbonMonoxideSensor,
            HMServiceTypeLeakSensor,
            HMServiceTypeIrrigationSystem,
            HMServiceTypeValve,
            HMServiceTypeFaucet,
        ]
        if highRiskServiceTypes.contains(serviceType) { return true }
        let highRiskCharacteristicTypes: Set<String> = [
            HMCharacteristicTypeSecuritySystemAlarmType,
            HMCharacteristicTypeAdminOnlyAccess,
            HMCharacteristicTypeLockManagementControlPoint,
            HMCharacteristicTypeLockManagementAutoSecureTimeout,
            HMCharacteristicTypeCurrentSecuritySystemState,
            HMCharacteristicTypeTargetSecuritySystemState,
            HMCharacteristicTypeCurrentDoorState,
            HMCharacteristicTypeTargetDoorState,
            HMCharacteristicTypeCurrentLockMechanismState,
            HMCharacteristicTypeTargetLockMechanismState,
            HMCharacteristicTypeSmokeDetected,
            HMCharacteristicTypeCarbonMonoxideDetected,
            HMCharacteristicTypeCarbonDioxideDetected,
            HMCharacteristicTypeLeakDetected,
        ]
        if !highRiskCharacteristicTypes.isDisjoint(with: characteristicTypes) { return true }
        let description = serviceName.lowercased()
        return ["lock", "garage", "security", "alarm", "access control", "camera", "emergency"]
            .contains(where: description.contains)
    }
}
