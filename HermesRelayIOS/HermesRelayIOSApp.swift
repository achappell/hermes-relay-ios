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
        let appDirectory = applicationSupport.appendingPathComponent("HermesRelayIOS")
        let configuration = RelayConfigurationStore(
            secureStore: KeychainSecureValueStore(),
            profileURL: appDirectory.appendingPathComponent("profile.json")
        )
        let persistence = JSONConversationPersistence(
            fileURL: appDirectory.appendingPathComponent("conversation.json")
        )
        _store = State(
            initialValue: ConversationStore(
                configurationStore: configuration,
                persistence: persistence
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .task {
                    await store.loadPersistedConversation()
                }
        }
    }
}
