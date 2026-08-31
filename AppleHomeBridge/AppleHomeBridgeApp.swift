import SwiftUI

@main
struct AppleHomeBridgeApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                Color.clear
            } else {
                BridgeRootView()
            }
        }
    }
}

private struct BridgeRootView: View {
    @StateObject private var model = BridgeAppModel()

    var body: some View {
        ContentView(model: model)
    }
}
