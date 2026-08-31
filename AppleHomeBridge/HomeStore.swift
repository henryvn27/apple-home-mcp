import Foundation

@MainActor
protocol HomeStore: AnyObject {
    var status: StoreStatus { get }
    func inventory() throws -> [HomeRecord]
    func read(_ reference: CharacteristicReference) async throws -> JSONValue
    func writeApproval(
        _ reference: CharacteristicReference,
        value: JSONValue
    ) throws -> ApprovalPresentation?
    func write(
        _ reference: CharacteristicReference,
        value: JSONValue,
        humanApprovalGranted: Bool
    ) async throws
    func scenes() throws -> [SceneRecord]
    func sceneApproval(_ reference: SceneReference) throws -> ApprovalPresentation?
    func runScene(_ reference: SceneReference, humanApprovalGranted: Bool) async throws
}
