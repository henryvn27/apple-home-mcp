import Foundation

@MainActor
protocol HomeStore: AnyObject {
    var status: StoreStatus { get }
    func inventory() throws -> [HomeRecord]
    func read(_ reference: CharacteristicReference) async throws -> JSONValue
    func write(_ reference: CharacteristicReference, value: JSONValue) async throws
    func scenes() throws -> [SceneRecord]
    func runScene(_ reference: SceneReference) async throws
    func characteristicRequiresHumanApproval(_ reference: CharacteristicReference) throws -> Bool
    func sceneRequiresHumanApproval(_ reference: SceneReference) throws -> Bool
}
