import SwiftUI

@MainActor
@main
struct HermesRelayIOSApp: App {
    @State private var store: ConversationStore
    private let configuration: RelayConfigurationStore
    private let deviceDiscoveryClient: any DeviceDiscoveryClient
    private let deviceAdministrationClient: any DeviceAdministrationClient
    private let deviceSetupDraftStore: any DeviceSetupDraftStore
    private let deviceConfigurationStore: any DeviceConfigurationStore
    private let appDirectory: URL

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
        // One conversation per relay profile. The store swaps to the selected
        // profile's file when the client is configured.
        _store = State(
            initialValue: ConversationStore(
                configurationStore: configuration,
                makePersistence: { profileID in
                    JSONConversationPersistence(
                        fileURL: ConversationPersistenceFile.url(
                            in: appDirectory, for: profileID
                        )
                    )
                }
            )
        )
        self.appDirectory = appDirectory
        self.configuration = configuration
        // Device discovery stays behind the typed seam until Hermes and the
        // physical Device share a settled discovery/handshake contract. A
        // Debug-only launch argument selects the deterministic UI fixture.
        self.deviceDiscoveryClient = DeviceDiscoveryClientFactory.make()
        self.deviceAdministrationClient = DeviceAdministrationClientFactory.make()
        self.deviceSetupDraftStore = DeviceSetupDraftStoreFactory.make(in: appDirectory)
        self.deviceConfigurationStore = DeviceConfigurationStoreFactory.make(in: appDirectory)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                store: store,
                configurationStore: configuration,
                conversationDirectory: appDirectory,
                deviceDiscoveryClient: deviceDiscoveryClient,
                deviceAdministrationClient: deviceAdministrationClient,
                deviceSetupDraftStore: deviceSetupDraftStore,
                deviceConfigurationStore: deviceConfigurationStore
            )
                .task {
                    // Hand the pre-profiles conversation to whichever profile
                    // is active before anything reads it.
                    if let activeID = try? await configuration.loadProfile()?.id {
                        ConversationPersistenceMigrator.migrateLegacyConversation(
                            in: appDirectory, to: activeID
                        )
                    }
                    // Resolve the active profile first: it decides which
                    // conversation file to read. Loading before this ran
                    // against no persistence at all and restored nothing.
                    await store.loadConfiguredClient()
                    await store.loadPersistedConversation()
                    await store.autoConnectIfNeeded()
                }
        }
    }
}
