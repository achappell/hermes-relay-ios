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
    private let homeLiveConfigurationStore: JSONHomeLiveConfigurationStore
    private let homeCredentialStore: KeychainHomeCredentialStore
    private let homeClientFactory: AppHomeBridgeSessionClientFactory
    private let homeClaimProvider: AppHomeConversationClaimProvider

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
        let homeFakeEnabled = ProcessInfo.processInfo.arguments.contains("-HomeBridgeFake")
        let homeLiveConfigurationStore = JSONHomeLiveConfigurationStore(
            fileURL: appDirectory.appendingPathComponent("home-live-configurations.json")
        )
        let homeCredentialStore = KeychainHomeCredentialStore(
            secureStore: KeychainSecureValueStore()
        )
        let liveHomeFactory = DefaultHomeBridgeSessionClientFactory(
            dependencies: HomeBridgeClientDependencies(
                routeProvider: homeLiveConfigurationStore,
                credentialStore: homeCredentialStore,
                publicAdapterEnabled: true
            )
        )
        let homeClaimProvider = AppHomeConversationClaimProvider(
            fakeEnabled: homeFakeEnabled,
            liveStore: homeLiveConfigurationStore
        )
        let homeClientFactory = AppHomeBridgeSessionClientFactory(
            enabled: homeFakeEnabled,
            claimProvider: homeClaimProvider,
            liveFactory: liveHomeFactory
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
                },
                homeClientFactory: homeClientFactory,
                homeClaimProvider: homeClaimProvider
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
        self.homeLiveConfigurationStore = homeLiveConfigurationStore
        self.homeCredentialStore = homeCredentialStore
        self.homeClientFactory = homeClientFactory
        self.homeClaimProvider = homeClaimProvider
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
                deviceConfigurationStore: deviceConfigurationStore,
                homeClientFactory: homeClientFactory,
                homeClaimProvider: homeClaimProvider,
                homeLiveConfigurationStore: homeLiveConfigurationStore,
                homeCredentialStore: homeCredentialStore
            )
        }
    }
}
