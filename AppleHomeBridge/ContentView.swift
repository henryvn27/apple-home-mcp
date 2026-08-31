import Combine
import SwiftUI

@MainActor
final class BridgeAppModel: ObservableObject {
    let store = HomeKitStore()
    @Published private(set) var descriptor: BridgeDescriptor?
    @Published private(set) var status = StoreStatus(loaded: false, authorizationStatus: "not_determined", homeCount: 0)
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingApprovals: [PendingApproval] = []

    private let approvalGate = ApprovalGate()
    private var server: LoopbackBridgeServer?
    private var storeObservation: AnyCancellable?
    private var approvalObservation: AnyCancellable?

    init() {
        storeObservation = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        approvalObservation = approvalGate.$pending.sink { [weak self] pending in
            self?.pendingApprovals = pending
        }
        do {
#if targetEnvironment(macCatalyst)
            let token = try BridgeSecret.loadOrCreate()
            let service = BridgeService(store: store, token: token, approvalGate: approvalGate)
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

    func approve(_ request: PendingApproval) {
        approvalGate.approve(request.id)
    }

    func reject(_ request: PendingApproval) {
        approvalGate.reject(request.id)
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
                        "High-risk controls require a short-lived, exact, one-use approval here.",
                        systemImage: "lock.shield"
                    )
                }
                if !model.pendingApprovals.isEmpty {
                    Section("Pending approval") {
                        ForEach(model.pendingApprovals) { request in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(request.title).font(.headline)
                                Text(request.detail)
                                Text("Approval permits one identical retry for 60 seconds.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("Reject", role: .destructive) { model.reject(request) }
                                    Spacer()
                                    Button("Approve") { model.approve(request) }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                if let error = model.errorMessage {
                    Section("Bridge error") { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Apple Home Bridge")
        }
    }
}
