import SwiftUI

@MainActor
@main
struct HermesRelayIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let automaticDiagnostics: AutomaticDiagnosticsReporter
    @State private var store: ConversationStore
    private let configuration: RelayConfigurationStore
    private let deviceDiscoveryClient: any DeviceDiscoveryClient
    private let deviceAdministrationClient: any DeviceAdministrationClient
    private let deviceSetupDraftStore: any DeviceSetupDraftStore
    private let deviceConfigurationStore: any DeviceConfigurationStore
    private let appDirectory: URL
    private let homeLiveConfigurationStore: JSONHomeLiveConfigurationStore
    private let homeCredentialStore: KeychainHomeCredentialStore
    private let homeAdminCredentialStore: KeychainHomeAdminCredentialStore
    private let homeServiceClient: ProfileHomeServiceClient
    private let homeClientFactory: AppHomeBridgeSessionClientFactory
    private let homeClaimProvider: AppHomeConversationClaimProvider
    private let homePairingCoordinator: HomeClientPairingCoordinator
    @State private var pairingInbox = HomePairingLinkInbox()

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
        let homeAdminCredentialStore = KeychainHomeAdminCredentialStore(
            secureStore: KeychainSecureValueStore()
        )
        let homeServiceClient = ProfileHomeServiceClient(
            configurationStore: configuration,
            routeProvider: homeLiveConfigurationStore,
            adminCredentialStore: homeAdminCredentialStore
        )
        // Paired personal clients (HOME-NW-17): non-secret pairing records
        // beside the operator-provisioned store, which keeps working as is.
        let homePairingStore = JSONHomeClientPairingStore(
            fileURL: appDirectory.appendingPathComponent("home-client-pairings.json")
        )
        let homeClientService = URLSessionHomeClientService()
        let homeClaimCoordinator = HomeClientClaimCoordinator(
            service: homeClientService,
            pairings: homePairingStore,
            credentials: homeCredentialStore
        )
        let uploader = ClientDiagnosticUploader(transport: URLSessionHomeHTTPTransport(), credentials: homeCredentialStore)
        let automaticDiagnostics = AutomaticDiagnosticsReporter(
            fileURL: appDirectory.appendingPathComponent("Diagnostics/automatic-reports.json"),
            pairings: { try await homePairingStore.pairings() },
            upload: { pairing, report in try await uploader.send(pairing: pairing, report: report) }
        )
        self.automaticDiagnostics = automaticDiagnostics
        let liveHomeFactory = DefaultHomeBridgeSessionClientFactory(
            dependencies: HomeBridgeClientDependencies(
                routeProvider: AppHomeApprovedRouteProvider(
                    pairings: homePairingStore,
                    legacy: homeLiveConfigurationStore
                ),
                credentialStore: PairingAwareHomeCredentialStore(
                    pairings: homePairingStore,
                    credentials: homeCredentialStore
                ),
                diagnostics: HomeBridgeDiagnosticsFactory.make(),
                publicAdapterEnabled: true,
                routePinRecorder: homePairingStore
            ),
            reporter: automaticDiagnostics
        )
        let homeClaimProvider = AppHomeConversationClaimProvider(
            fakeEnabled: homeFakeEnabled,
            liveStore: homeLiveConfigurationStore,
            pairedClaims: homeClaimCoordinator
        )
        let homeClientFactory = AppHomeBridgeSessionClientFactory(
            enabled: homeFakeEnabled,
            claimProvider: homeClaimProvider,
            liveFactory: liveHomeFactory
        )
        let homePairingCoordinator = HomeClientPairingCoordinator(
            service: homeClientService,
            pairings: homePairingStore,
            credentials: homeCredentialStore,
            configurationStore: configuration,
            claimCoordinator: homeClaimCoordinator,
            homeClientFactory: homeClientFactory,
            identity: RelayDeviceIdentity.current()
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
        self.homeAdminCredentialStore = homeAdminCredentialStore
        self.homeServiceClient = homeServiceClient
        self.homeClientFactory = homeClientFactory
        self.homeClaimProvider = homeClaimProvider
        self.homePairingCoordinator = homePairingCoordinator
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
                homeServiceClient: homeServiceClient,
                homeClientFactory: homeClientFactory,
                homeClaimProvider: homeClaimProvider,
                homeLiveConfigurationStore: homeLiveConfigurationStore,
                homeCredentialStore: homeCredentialStore,
                homeAdminCredentialStore: homeAdminCredentialStore,
                homePairingCoordinator: homePairingCoordinator,
                pairingInbox: pairingInbox
            )
            .environment(\.automaticDiagnostics, automaticDiagnostics)
            .task(id: scenePhase) {
                let phase: ClientDiagnosticEvent.Name = scenePhase == .active ? .active : (scenePhase == .background ? .background : .inactive)
                await automaticDiagnostics.lifecycle(phase)
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await automaticDiagnostics.flush()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
            .onOpenURL { url in
                // Only `hermes-home://pair` links are handled; nothing is
                // submitted until the pairing sheet validates the link.
                pairingInbox.receive(url)
            }
        }
    }
}
