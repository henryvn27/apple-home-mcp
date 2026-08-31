import Combine
import CryptoKit
import Foundation

struct ApprovalPresentation: Equatable, Sendable {
    let title: String
    let detail: String
}

struct PendingApproval: Equatable, Identifiable, Sendable {
    let id: UUID
    let fingerprint: String
    let title: String
    let detail: String
    let requestedAt: Date
}

enum ApprovalFingerprint {
    static func write(reference: CharacteristicReference, value: JSONValue) throws -> String {
        let valueComponent: String
        switch value {
        case let .bool(value): valueComponent = "bool:\(value)"
        case let .number(value) where value.isFinite:
            valueComponent = "number:\(value.bitPattern)"
        case let .string(value):
            valueComponent = "string:\(Data(value.utf8).base64EncodedString())"
        default:
            throw BridgeError(
                "unsupported_value",
                "HomeKit array, dictionary, data, TLV8, and private formats cannot be written"
            )
        }
        return digest([
            "write_characteristic",
            reference.homeID,
            reference.accessoryID,
            reference.serviceID,
            reference.characteristicID,
            valueComponent,
        ])
    }

    static func scene(reference: SceneReference) -> String {
        digest(["run_scene", reference.homeID, reference.sceneID])
    }

    private static func digest(_ components: [String]) -> String {
        let canonical = components.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

@MainActor
final class ApprovalGate: ObservableObject {
    enum Decision: Equatable {
        case authorized
        case pending
        case queueFull
    }

    @Published private(set) var pending: [PendingApproval] = []

    let grantLifetime: TimeInterval
    private let monotonicNow: () -> TimeInterval
    private var grants: [String: TimeInterval] = [:]
    private let maximumPending = 32

    init(
        grantLifetime: TimeInterval = 60,
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.grantLifetime = grantLifetime.isFinite ? max(1, grantLifetime) : 60
        self.monotonicNow = monotonicNow
    }

    func authorizeOrQueue(
        fingerprint: String,
        presentation: ApprovalPresentation
    ) -> Decision {
        purgeExpiredGrants()
        if let expiration = grants[fingerprint], expiration > monotonicNow() {
            grants.removeValue(forKey: fingerprint)
            return .authorized
        }
        grants.removeValue(forKey: fingerprint)
        if pending.contains(where: { $0.fingerprint == fingerprint }) { return .pending }
        guard pending.count < maximumPending else { return .queueFull }
        pending.append(PendingApproval(
            id: UUID(),
            fingerprint: fingerprint,
            title: presentation.title,
            detail: presentation.detail,
            requestedAt: Date()
        ))
        return .pending
    }

    func approve(_ id: UUID) {
        purgeExpiredGrants()
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        grants[request.fingerprint] = monotonicNow() + grantLifetime
    }

    func reject(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        grants.removeValue(forKey: request.fingerprint)
    }

    private func purgeExpiredGrants() {
        let current = monotonicNow()
        grants = grants.filter { $0.value > current }
    }
}
