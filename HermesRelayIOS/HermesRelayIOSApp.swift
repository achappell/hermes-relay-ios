import SwiftUI

@MainActor
@main
struct HermesRelayIOSApp: App {
    @State private var store: ConversationStore

    init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let configuration = RelayConfigurationStore(
            secureStore: KeychainSecureValueStore(),
            profileURL: applicationSupport
                .appendingPathComponent("HermesRelayIOS")
                .appendingPathComponent("profile.json")
        )
        _store = State(initialValue: ConversationStore(configurationStore: configuration))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}
