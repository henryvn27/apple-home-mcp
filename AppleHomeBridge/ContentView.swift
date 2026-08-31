import Combine
import SwiftUI

@MainActor
final class BridgeAppModel: ObservableObject {
    let store = HomeKitStore()
    @Published private(set) var descriptor: BridgeDescriptor?
    @Published private(set) var status = StoreStatus(loaded: false, authorizationStatus: "not_determined", homeCount: 0)
    @Published private(set) var errorMessage: String?

    private var server: LoopbackBridgeServer?
    private var storeObservation: AnyCancellable?

    init() {
        storeObservation = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        do {
#if targetEnvironment(macCatalyst)
            let token = try BridgeSecret.loadOrCreate()
            let service = BridgeService(store: store, token: token)
            let server = LoopbackBridgeServer(service: service, token: token)
            descriptor = try server.start()
            self.server = server
#endif
        } catch let error as BridgeError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        status = store.status
    }
}

struct ContentView: View {
    @ObservedObject var model: BridgeAppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Bridge") {
                    LabeledContent("Listener", value: model.descriptor.map { "127.0.0.1:\($0.port)" } ?? "Stopped")
                    LabeledContent("Protocol", value: "Authenticated JSON lines")
                    LabeledContent("Descriptor", value: "Owner-only (0600)")
                }
                Section("Apple Home") {
                    LabeledContent(
                        "Authorization",
                        value: model.status.authorizationStatus
                            .replacingOccurrences(of: "_", with: " ")
                            .capitalized
                    )
                    LabeledContent("Homes", value: String(model.status.homeCount))
                    LabeledContent("Graph", value: model.status.loaded ? "Loaded" : "Loading")
                    Button("Refresh") { model.refresh() }
                }
                Section("Safety") {
                    Label("Every write and scene requires confirm=true.", systemImage: "checkmark.shield")
                    Label(
                        "Locks, garage doors, security, cameras, alarms, access control, and emergency services fail closed.",
                        systemImage: "lock.shield"
                    )
                }
                if let error = model.errorMessage {
                    Section("Bridge error") { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Apple Home Bridge")
        }
    }
}
