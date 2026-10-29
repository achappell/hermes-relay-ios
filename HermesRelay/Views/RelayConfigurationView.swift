import SwiftUI
import Observation

extension RelayConfigurationDraft {
    /// Endpoint changes are new local connections, never credential moves.
    func legacyConnection(
        original: RelayProfile?, storedToken: String?
    ) throws -> (profile: RelayProfile, token: String) {
        let candidate = try makeProfile(id: original?.id)
        let endpointChanged = original.map { $0.endpoint != candidate.endpoint } ?? true
        let token = try tokenToSave(existingToken: endpointChanged ? nil : storedToken)
        let profile = endpointChanged && original != nil ? try makeProfile() : candidate
        return (profile, token)
    }
}

/// The profile list's state. The view stays a thin shell over this so the
/// select and delete behaviour is assertable without driving SwiftUI.
@MainActor
@Observable
final class RelayProfileListModel {
    private(set) var collection = RelayProfileCollection()
    /// App profiles bound to a Home pairing grant.
    private(set) var pairedProfileIDs: Set<UUID> = []
    private(set) var pairings: [HomeClientPairing] = []
    var errorMessage: String?

    private let configurationStore: RelayConfigurationStore
    private let homeAdminCredentialStore: (any HomeAdminCredentialStore)?
    private let homePairingCoordinator: HomeClientPairingCoordinator?
    /// Where per-profile conversations live, so deleting a profile takes its
    /// messages with it rather than leaving them readable on disk.
    private let conversationDirectory: URL?

    init(
        configurationStore: RelayConfigurationStore,
        conversationDirectory: URL? = nil,
        homeAdminCredentialStore: (any HomeAdminCredentialStore)? = nil,
        homePairingCoordinator: HomeClientPairingCoordinator? = nil
    ) {
        self.configurationStore = configurationStore
        self.conversationDirectory = conversationDirectory
        self.homeAdminCredentialStore = homeAdminCredentialStore
        self.homePairingCoordinator = homePairingCoordinator
    }

    func load() async {
        do {
            collection = try await configurationStore.loadCollection()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        if collection.selectedProfile?.standardProfile == nil,
           let homePairingCoordinator,
           let pairings = try? await homePairingCoordinator.allPairings() {
            self.pairings = pairings
            pairedProfileIDs = Set(pairings.flatMap { $0.profiles.map(\.profileID) })
        } else {
            pairings = []
            pairedProfileIDs = []
        }
    }

    func select(id: UUID) async {
        do {
            try await configurationStore.selectProfile(id: id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func delete(id: UUID) async -> Bool {
        do {
            if collection.profiles.first(where: { $0.id == id })?.standardProfile != nil {
                try await configurationStore.deleteProfile(id: id)
                if let conversationDirectory {
                    try ConversationPersistenceFile.delete(in: conversationDirectory, for: id)
                }
                await load()
                return true
            }
            try await configurationStore.deleteProfile(id: id)
            var pairingCleanupFailed = false
            do {
                // A Home's last paired profile takes its Keychain credential
                // with it.
                try await homePairingCoordinator?.profileRemoved(id)
            } catch {
                pairingCleanupFailed = true
            }
            do {
                try await homeAdminCredentialStore?.delete(for: id)
            } catch {
                if let conversationDirectory {
                    try? ConversationPersistenceFile.delete(in: conversationDirectory, for: id)
                }
                await load()
                errorMessage = "The Profile was deleted, but its Home admin credential could not be removed. Remove it from Keychain before reusing this device."
                return true
            }
            if let conversationDirectory {
                try? ConversationPersistenceFile.delete(in: conversationDirectory, for: id)
            }
            await load()
            if pairingCleanupFailed {
                errorMessage = "The Profile was deleted, but its Home pairing could not be cleaned up. Pairing this Home again replaces the stored credential."
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Forgets a Home locally: its saved profiles and their transcripts first,
    /// then the pairing record and Keychain credential. A failure part-way
    /// leaves the pairing in place so Unpair can be tried again. Returns
    /// whether the selected profile was among those removed.
    func unpair(pairingID: UUID) async throws -> Bool {
        guard let homePairingCoordinator else { throw HomeClientPairingStoreError.unknownPairing }
        guard let pairing = try await homePairingCoordinator.allPairings().first(where: { $0.id == pairingID }) else {
            throw HomeClientPairingStoreError.unknownPairing
        }
        let current = try await configurationStore.loadCollection()
        let removedIDs = Set(pairing.profiles.map(\.profileID))
        let removedSelected = current.selectedID.map { removedIDs.contains($0) } ?? false
        var adminCleanupFailed = false
        for profileID in removedIDs where current.profiles.contains(where: { $0.id == profileID }) {
            try await configurationStore.deleteProfile(id: profileID)
            do {
                try await homeAdminCredentialStore?.delete(for: profileID)
            } catch {
                adminCleanupFailed = true
            }
            if let conversationDirectory {
                try? ConversationPersistenceFile.delete(in: conversationDirectory, for: profileID)
            }
        }
        do {
            _ = try await homePairingCoordinator.unpair(pairingID: pairingID)
        } catch {
            await load()
            throw error
        }
        await load()
        if adminCleanupFailed {
            errorMessage = "The Home was unpaired, but a Home admin credential could not be removed. Remove it from Keychain before reusing this device."
        }
        return removedSelected
    }
}

@MainActor
struct HomeLiveSetupView: View {
    let configurationStore: RelayConfigurationStore
    let credentialStore: any HomeCredentialProvisioningStore
    let liveConfigurationStore: any HomeLiveConfigurationStore
    let homeClientFactory: any HomeBridgeSessionClientFactory
    let onActivated: @MainActor () async -> Void
    let reconfigurationBlockedReason: @MainActor () -> String?
    let beginReconfiguration: @MainActor () async -> Bool
    let endReconfiguration: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var profile: RelayProfile?
    @State private var endpoint = ""
    @State private var routeID = "local"
    @State private var householdBinding = ""
    @State private var conversationHandle = ""
    @State private var deviceCredential = ""
    @State private var hasStoredCredential = false
    @State private var isLoading = false
    @State private var isActivating = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    init(
        configurationStore: RelayConfigurationStore,
        credentialStore: any HomeCredentialProvisioningStore,
        liveConfigurationStore: any HomeLiveConfigurationStore,
        homeClientFactory: any HomeBridgeSessionClientFactory,
        reconfigurationBlockedReason: @escaping @MainActor () -> String? = { nil },
        beginReconfiguration: @escaping @MainActor () async -> Bool = { true },
        endReconfiguration: @escaping @MainActor () -> Void = {},
        onActivated: @escaping @MainActor () async -> Void = {}
    ) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
        self.liveConfigurationStore = liveConfigurationStore
        self.homeClientFactory = homeClientFactory
        self.reconfigurationBlockedReason = reconfigurationBlockedReason
        self.beginReconfiguration = beginReconfiguration
        self.endReconfiguration = endReconfiguration
        self.onActivated = onActivated
    }

    var body: some View {
        NavigationStack {
            Form {
                if let profile {
                    Section {
                        LabeledContent("Profile", value: profile.displayName)
                        Text("The live Home claim and credential will be bound to this Profile. Switch Profiles in the previous screen before setting up another one.")
                            .font(.footnote)
                            .foregroundStyle(HermesVisualTokens.secondaryInk)
                    } header: {
                        Text("Selected Hermes Profile")
                    }
                }

                Section {
                    TextField("wss://home-host/api/v1/bridge/ws", text: $endpoint)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                } header: {
                    Text("Approved Home route")
                } footer: {
                    Text("Use the tailnet-only wss:// Home route. The path must be exactly /api/v1/bridge/ws; credentials and query strings are rejected.")
                }

                Section {
                    TextField("Route ID", text: $routeID)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                    TextField("Household receipt", text: $householdBinding)
                        .autocorrectionDisabled()
                    TextField("Opaque conversation handle", text: $conversationHandle)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                } header: {
                    Text("Approved Home claim")
                } footer: {
                    Text("Copy the handle from the active Home conversation grant. Route ID must match HERMES_HOME_BRIDGE_ROUTE_ID. Household receipt is a local label for the approved household binding.")
                }

                Section {
                    SecureField("Pre-issued Device credential", text: $deviceCredential)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                    if hasStoredCredential {
                        Label(
                            "A Home Device credential is already stored. Leave this blank to reuse it, or enter a value to replace it.",
                            systemImage: "checkmark.shield"
                        )
                        .font(.footnote)
                        .foregroundStyle(HermesVisualTokens.secondaryInk)
                    }
                    Text("The credential is written directly to Keychain and is never saved in this form, the profile file, logs, or validation artifacts.")
                        .font(.footnote)
                        .foregroundStyle(HermesVisualTokens.secondaryInk)
                } header: {
                    Text("Device authorization")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(HermesVisualTokens.unavailable)
                    }
                }

                if let statusMessage {
                    Section {
                        Label(statusMessage, systemImage: "checkmark.circle")
                            .foregroundStyle(HermesVisualTokens.secondaryInk)
                    }
                }

                Section {
                    Button("Activate Home bridge") {
                        Task { await activate() }
                    }
                    .disabled(
                        profile == nil
                            || isLoading
                            || isActivating
                    )
                    .accessibilityIdentifier("activate-home-bridge")
                } footer: {
                    Text("Activation performs one live conversation.open handshake. If it fails, the app stays on the legacy relay path and keeps the metadata available for correction and retry.")
                }
            }
            .navigationTitle("Live Home setup")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .overlay {
                if isLoading || isActivating {
                    ProgressView(isActivating ? "Proving Home bridge…" : "Loading Home setup…")
                        .padding(20)
                        .relayPanel(cornerRadius: 16, fill: HermesVisualTokens.panel)
                }
            }
            .task {
                await load()
            }
        }
    }

    private func load() async {
        guard profile == nil else { return }
        isLoading = true
        errorMessage = nil

        do {
            guard let loadedProfile = try await configurationStore.loadProfile() else {
                errorMessage = "Select or save a Hermes Profile before setting up Home."
                isLoading = false
                return
            }
            profile = loadedProfile
            if let configuration = try await liveConfigurationStore.configuration(
                for: loadedProfile.id
            ) {
                endpoint = configuration.approvedRoute.endpoint.absoluteString
                routeID = configuration.approvedRoute.identity.id
                householdBinding = configuration.approvedRoute.householdBinding
                conversationHandle = configuration.conversationHandle
            }
            hasStoredCredential = (try? await credentialStore.verifiedReadBack(
                for: loadedProfile.id
            )) != nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func activate() async {
        guard !isActivating else { return }
        if let reason = reconfigurationBlockedReason() {
            errorMessage = reason
            return
        }
        guard let profile else {
            errorMessage = "Select a Hermes Profile before activating Home."
            return
        }

        let normalizedEndpoint = endpoint.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let endpointURL = URL(string: normalizedEndpoint) else {
            errorMessage = "Enter the approved Home wss:// bridge route."
            return
        }
        isActivating = true
        defer { isActivating = false }
        guard await beginReconfiguration() else {
            errorMessage = reconfigurationBlockedReason() ?? "Another connection change is already in progress."
            return
        }
        defer { endReconfiguration() }

        do {
            let route = HomeApprovedRoute(
                endpoint: endpointURL,
                identity: HomeRouteIdentity(
                    routeClass: .home,
                    id: routeID
                ),
                householdBinding: householdBinding
            )
            let liveConfiguration = try HomeLiveConfiguration(
                profileID: profile.id,
                conversationHandle: conversationHandle,
                approvedRoute: route
            )
            errorMessage = nil
            statusMessage = nil
            let activation = HomeLiveActivation(
                configurationStore: configurationStore,
                credentialStore: credentialStore,
                liveConfigurationStore: liveConfigurationStore,
                homeClientFactory: homeClientFactory
            )
            let result = try await activation.activate(
                profileID: profile.id,
                liveConfiguration: liveConfiguration,
                deviceCredential: Data(deviceCredential.utf8)
            )
            guard result == .selectedHome else {
                errorMessage = "Home was not selected after the live handshake."
                return
            }
            hasStoredCredential = true
            deviceCredential = ""
            statusMessage = "Home bridge is active for \(profile.displayName). Connect again to use it."
            await onActivated()
        } catch {
            errorMessage = error.localizedDescription
            await onActivated()
        }

    }
}

@MainActor
struct RelayConfigurationView: View {
    /// Voice interruption opt-in (IOS-UX-F5); read by the voice coordinator.
    @AppStorage(VoicePreferences.interruptByTalkingKey) private var interruptByTalking = false
    @Environment(\.automaticDiagnostics) private var automaticDiagnostics
    let configurationStore: RelayConfigurationStore
    /// Live connection state, so the list can show which profile is actually
    /// connected rather than only which one is selected.
    let connectionState: ConnectionState
    let isStandardMode: Bool
    let conversationDirectory: URL?
    let deviceDiscoveryClient: any DeviceDiscoveryClient
    let deviceAdministrationClient: any DeviceAdministrationClient
    let deviceSetupDraftStore: any DeviceSetupDraftStore
    let deviceConfigurationStore: any DeviceConfigurationStore
    let homeServiceClient: (any HomeServiceClient)?
    let homeLiveConfigurationStore: (any HomeLiveConfigurationStore)?
    let homeCredentialStore: (any HomeCredentialProvisioningStore)?
    let homeAdminCredentialStore: (any HomeAdminCredentialStore)?
    let homeClientFactory: (any HomeBridgeSessionClientFactory)?
    let homePairingCoordinator: HomeClientPairingCoordinator?
    let connectionChangeBlockedReason: String?
    let reconfigurationBlockedReason: @MainActor () -> String?
    let beginReconfiguration: @MainActor () async -> Bool
    let endReconfiguration: @MainActor () -> Void
    let onSaved: @MainActor () async -> Void
    let onSelectedProfileDeleted: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: RelayConfigurationDraft
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isReconfiguring = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var didLoad = false
    @State private var listModel: RelayProfileListModel
    @State private var showingDeviceDiscovery = false
    @State private var showingHomeSetup = false
    @State private var showingHomePairing = false
    @State private var refreshingHomeID: UUID?
    @State private var homeRefreshMessages: [UUID: String] = [:]
    @State private var homeAdminCredential = ""
    @State private var hasStoredHomeAdminCredential = false
    @State private var homeAdminHouseholdBinding: String?
    @State private var isSavingHomeAdminCredential = false
    @FocusState private var focusedField: RelayConfigurationField?
    @State private var didAttemptValidation = false
    /// Which saved profile the form is editing. Nil means the form is
    /// composing a new one, so saving must not overwrite the active profile.
    @State private var editingProfileID: UUID?
    @State private var setupChoice: NewConnectionChoice?

    private enum NewConnectionChoice {
        case home, standard
    }

    private var editingProfile: RelayProfile? {
        listModel.collection.profiles.first { $0.id == editingProfileID }
    }

    private var isStandardSetup: Bool {
        setupChoice == .standard || editingProfile?.standardProfile != nil
    }

    private var showsHomeSettings: Bool {
        !isStandardSetup && (editingProfileID != nil || setupChoice == .home)
    }

    private var isLegacyEditor: Bool {
        guard let editingProfileID else { return false }
        return listModel.collection.transportMode(for: editingProfileID) == .legacy
    }

    init(
        configurationStore: RelayConfigurationStore,
        connectionState: ConnectionState = .disconnected,
        isStandardMode: Bool = false,
        conversationDirectory: URL? = nil,
        deviceDiscoveryClient: any DeviceDiscoveryClient = UnavailableDeviceDiscoveryClient(),
        deviceAdministrationClient: any DeviceAdministrationClient = UnavailableDeviceAdministrationClient(),
        deviceSetupDraftStore: any DeviceSetupDraftStore = NoopDeviceSetupDraftStore(),
        deviceConfigurationStore: any DeviceConfigurationStore = NoopDeviceConfigurationStore(),
        homeServiceClient: (any HomeServiceClient)? = nil,
        homeLiveConfigurationStore: (any HomeLiveConfigurationStore)? = nil,
        homeCredentialStore: (any HomeCredentialProvisioningStore)? = nil,
        homeAdminCredentialStore: (any HomeAdminCredentialStore)? = nil,
        homeClientFactory: (any HomeBridgeSessionClientFactory)? = nil,
        homePairingCoordinator: HomeClientPairingCoordinator? = nil,
        connectionChangeBlockedReason: String? = nil,
        reconfigurationBlockedReason: @escaping @MainActor () -> String? = { nil },
        beginReconfiguration: @escaping @MainActor () async -> Bool = { true },
        endReconfiguration: @escaping @MainActor () -> Void = {},
        onSaved: @escaping @MainActor () async -> Void = {},
        onSelectedProfileDeleted: @escaping @MainActor () async -> Void = {}
    ) {
        self.configurationStore = configurationStore
        self.connectionState = connectionState
        self.isStandardMode = isStandardMode
        self.conversationDirectory = conversationDirectory
        self.deviceDiscoveryClient = deviceDiscoveryClient
        self.deviceAdministrationClient = deviceAdministrationClient
        self.deviceSetupDraftStore = deviceSetupDraftStore
        self.deviceConfigurationStore = deviceConfigurationStore
        self.homeServiceClient = homeServiceClient
        self.homeLiveConfigurationStore = homeLiveConfigurationStore
        self.homeCredentialStore = homeCredentialStore
        self.homeAdminCredentialStore = homeAdminCredentialStore
        self.homeClientFactory = homeClientFactory
        self.homePairingCoordinator = homePairingCoordinator
        self.connectionChangeBlockedReason = connectionChangeBlockedReason
        self.reconfigurationBlockedReason = reconfigurationBlockedReason
        self.beginReconfiguration = beginReconfiguration
        self.endReconfiguration = endReconfiguration
        self.onSaved = onSaved
        self.onSelectedProfileDeleted = onSelectedProfileDeleted
        _draft = State(initialValue: RelayConfigurationDraft(identity: .current()))
        _listModel = State(
            initialValue: RelayProfileListModel(
                configurationStore: configurationStore,
                conversationDirectory: conversationDirectory,
                homeAdminCredentialStore: homeAdminCredentialStore,
                homePairingCoordinator: homePairingCoordinator
            )
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if let connectionChangeBlockedReason {
                    Section {
                        Label(connectionChangeBlockedReason, systemImage: "lock")
                        Text("Resolve the turn or use Leave this conversation on the conversation screen before changing connections.")
                            .font(.footnote)
                    } header: {
                        Text("Connection changes unavailable")
                    }
                }
                if !listModel.collection.profiles.isEmpty {
                    Section {
                        ForEach(listModel.collection.profiles, id: \.id) { profile in
                            Button {
                                Task { await select(profile) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.displayName)
                                        Text(
                                            "\(modeLabel(for: profile)) · \(profile.endpoint.host ?? "Saved connection")\(profile.standardProfile.map { " · \($0) · \(profile.id.uuidString.prefix(8))" } ?? "")"
                                        )
                                            .font(.caption)
                                            .foregroundStyle(HermesVisualTokens.secondaryInk)
                                    }
                                    Spacer(minLength: 8)
                                    if profile.id == listModel.collection.selectedID {
                                        Label(
                                            connectionState.label,
                                            systemImage: connectionState.isConnected
                                                ? "checkmark.circle.fill"
                                                : "circle.dotted"
                                        )
                                        .labelStyle(.titleAndIcon)
                                        .font(.caption)
                                        .foregroundStyle(
                                            connectionState.isConnected ? HermesVisualTokens.live : HermesVisualTokens.secondaryInk
                                        )
                                        .accessibilityLabel(
                                            "Active profile, \(connectionState.label)"
                                        )
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    Task { await delete(profile) }
                                }
                            }
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    Task { await delete(profile) }
                                }
                            }
                        }

                        Button("Add profile") {
                            addProfile()
                        }
                        .disabled(isLoading || isSaving || connectionChangeBlockedReason != nil)
                    } header: {
                        Text("Saved profiles")
                    } footer: {
                        Text("The checked profile is the one Connect uses.")
                    }
                }
                if editingProfileID == nil {
                    Section {
                        Button("HomeBridge — pair with Home") {
                            Task { await chooseConnection(.home) }
                        }
                        .accessibilityIdentifier("choose-homebridge")
                        Button("Standard Hermes — connect directly") {
                            Task { await chooseConnection(.standard) }
                        }
                        .accessibilityIdentifier("choose-standard")
                        if setupChoice == .home, homePairingCoordinator == nil {
                            Text("Home pairing is unavailable in this installation.")
                        }
                    } header: {
                        Text("Choose a connection")
                    } footer: {
                        Text("HomeBridge uses Home enrollment. Standard connects directly with a Standard token. Existing Legacy connections remain available in Saved profiles.")
                    }
                    .disabled(connectionChangeBlockedReason != nil || isSaving)
                }

                if isStandardSetup {
                    StandardSetupSection(
                        profile: editingProfile,
                        configurationStore: configurationStore,
                        connectionChangeBlockedReason: connectionChangeBlockedReason,
                        reconfigurationBlockedReason: currentBlockedReason,
                        beginReconfiguration: beginConnectionChange,
                        endReconfiguration: endConnectionChange,
                        onSaved: {
                            await listModel.load()
                            editingProfileID = listModel.collection.selectedID
                            setupChoice = nil
                            statusMessage = "Standard connection saved. Earlier connections and their history remain on this device; select a saved connection to view its transcript. Nothing was copied or resent."
                            await onSaved()
                        }
                    )
                    .id(editingProfileID?.uuidString ?? "new-standard")
                }

                if showsHomeSettings {

                if let editingProfile, !isLegacyEditor {
                    Section {
                        LabeledContent("Connection mode", value: modeLabel(for: editingProfile))
                    }
                }
                #if os(iOS)
                Section {
                    Button {
                        guard allowReconfiguration() else { return }
                        showingDeviceDiscovery = true
                    } label: {
                        Label(
                            "Manage household Devices",
                            systemImage: "dot.radiowaves.left.and.right"
                        )
                    }
                    Text("Discover a Device before approving it.")
                        .font(.footnote)
                        .foregroundStyle(HermesVisualTokens.secondaryInk)
                } header: {
                    Text("Household Devices")
                }
                #endif

                if let homePairingCoordinator {
                    Section {
                        ForEach(listModel.pairings) { pairing in
                            NavigationLink {
                                HomeOwnerAdministrationView(
                                    model: HomeOwnerAdministrationModel(
                                        pairingID: pairing.id,
                                        homeName: pairing.home.displayName,
                                        coordinator: homePairingCoordinator,
                                        performUnpair: { try await unpair(pairingID: pairing.id) }
                                    )
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pairing.home.displayName)
                                    Text(pairing.credentialUsable
                                        ? "Approve requests, see devices, or unpair"
                                        : "Pair again to use this Home")
                                        .font(.caption)
                                        .foregroundStyle(HermesVisualTokens.secondaryInk)
                                }
                            }
                            .accessibilityIdentifier("manage-home-pairing")
                            Button {
                                Task { await refreshHomeProfiles(pairingID: pairing.id) }
                            } label: {
                                HStack {
                                    Label("Refresh Profiles", systemImage: "arrow.clockwise")
                                    Spacer()
                                    if refreshingHomeID == pairing.id {
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(refreshingHomeID != nil || !pairing.credentialUsable)
                            .accessibilityLabel("Refresh Profiles for \(pairing.home.displayName)")
                            .accessibilityIdentifier("refresh-home-profiles")
                            if let message = homeRefreshMessages[pairing.id] {
                                Text(message)
                                    .font(.footnote)
                                    .foregroundStyle(HermesVisualTokens.secondaryInk)
                            }
                        }
                        Button {
                            guard allowReconfiguration() else { return }
                            showingHomePairing = true
                        } label: {
                            Label("Pair with Home", systemImage: "house.and.flag.fill")
                        }
                        .accessibilityIdentifier("pair-with-home")
                        Text("Use the link, QR code, or short code from the Home pairing page. Each Profile Home grants appears here as its own saved profile.")
                            .font(.footnote)
                            .foregroundStyle(HermesVisualTokens.secondaryInk)
                    } header: {
                        Text("Home pairing")
                    } footer: {
                        Text("After a Profile owner approves this device, refresh its Profiles here. The Home credential is stored in Keychain and renewed automatically.")
                    }
                }

                if editingProfileID != nil,
                   homeLiveConfigurationStore != nil,
                   homeCredentialStore != nil,
                   homeClientFactory != nil {
                    Section {
                        Button {
                            guard allowReconfiguration() else { return }
                            showingHomeSetup = true
                        } label: {
                            Label(
                                "Set up live Home bridge",
                                systemImage: "house.and.flag"
                            )
                        }
                        Text("Uses the approved opaque Home claim and stores the Device credential only in Keychain.")
                            .font(.footnote)
                            .foregroundStyle(HermesVisualTokens.secondaryInk)
                    } header: {
                        Text("Home bridge")
                    } footer: {
                        Text("Home mode is selected only after a live conversation.open handshake succeeds. Legacy relay access remains available for rollback.")
                    }
                }

                if homeAdminCredentialStore != nil {
                    Section {
                        SecureField("Home admin credential", text: $homeAdminCredential)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.asciiCapable)
                            #endif
                        if hasStoredHomeAdminCredential {
                            Label(
                                "A Home admin credential is bound to the approved Home household. Leave this blank to keep it, or enter a replacement.",
                                systemImage: "checkmark.shield"
                            )
                            .font(.footnote)
                            .foregroundStyle(HermesVisualTokens.secondaryInk)
                            Button("Save Home admin credential") {
                                Task { await saveHomeAdminCredential() }
                            }
                            .disabled(
                                editingProfileID == nil
                                    || isLoading
                                    || isSaving
                                    || isSavingHomeAdminCredential
                            )
                            Button("Remove Home admin credential", role: .destructive) {
                                Task { await removeHomeAdminCredential() }
                            }
                            .disabled(
                                editingProfileID == nil
                                    || isLoading
                                    || isSaving
                                    || isSavingHomeAdminCredential
                            )
                        } else {
                            Text(
                                homeAdminHouseholdBinding == nil
                                    ? "Set up an approved Home route before saving this credential."
                                    : "Required to manage household Devices through Home. Stored only in the dedicated Home-admin Keychain record."
                            )
                                .font(.footnote)
                                .foregroundStyle(HermesVisualTokens.secondaryInk)
                            Button("Save Home admin credential") {
                                Task { await saveHomeAdminCredential() }
                            }
                            .disabled(
                                editingProfileID == nil
                                    || isLoading
                                    || isSaving
                                    || isSavingHomeAdminCredential
                            )
                        }
                    } header: {
                        Text("Home administration")
                    } footer: {
                        Text("This bearer is distinct from the relay token and every per-Device credential. It is sent only to the approved Home configuration route.")
                    }
                }
                }

                if isLegacyEditor {
                Section {
                    LabeledContent("Connection mode", value: "Legacy relay")
                    Text("This existing fork-relay connection remains editable. Use Add profile for a separate HomeBridge or Standard connection.")
                        .font(.footnote)
                }

                Section {
                    TextField("Endpoint", text: $draft.endpoint)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .endpoint)
                        .onSubmit { focusedField = .clientID }
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    validationMessage(for: .endpoint)
                } header: {
                    Text("Relay endpoint")
                } footer: {
                    Text("Required. Use a ws:// or wss:// WebSocket endpoint.")
                }

                Section {
                    TextField("Client ID", text: $draft.clientID)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .clientID)
                        .onSubmit { focusedField = .deviceID }
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                    validationMessage(for: .clientID)
                    TextField("Device ID", text: $draft.deviceID)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .deviceID)
                        .onSubmit { focusedField = .displayName }
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                    validationMessage(for: .deviceID)
                    TextField("Display name", text: $draft.displayName)
                        .focused($focusedField, equals: .displayName)
                        .onSubmit { focusedField = .token }
                    validationMessage(for: .displayName)
                } header: {
                    Text("Device identity")
                } footer: {
                    Text("Client and device IDs start from this device’s name and remain editable.")
                }

                Section {
                    SecureField("Bearer token", text: $draft.token)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .token)
                        .onSubmit { focusedField = nil }
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                    validationMessage(for: .token)
                    if draft.hasStoredToken {
                        Label(
                            "Stored token available. Leave blank to keep it, or enter a new token to replace it.",
                            systemImage: "checkmark.shield"
                        )
                        .font(.footnote)
                        .foregroundStyle(HermesVisualTokens.secondaryInk)
                    } else {
                        Text("Required before saving. Stored securely in Keychain and never written to the profile file.")
                            .font(.footnote)
                            .foregroundStyle(HermesVisualTokens.secondaryInk)
                    }
                } header: {
                    Text("Credentials")
                }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(HermesVisualTokens.unavailable)
                    }
                }

                if let statusMessage {
                    Section {
                        Label(statusMessage, systemImage: "checkmark.circle")
                            .foregroundStyle(HermesVisualTokens.secondaryInk)
                    }
                }

                if isLegacyEditor {
                Section {
                    Button("Save configuration") {
                        Task { await save() }
                    }
                    .disabled(isLoading || isSaving)

                    if draft.hasStoredToken {
                        Button("Remove stored token", role: .destructive) {
                            Task { await removeToken() }
                        }
                        .disabled(isLoading || isSaving)
                    }
                }
                }

                #if os(iOS)
                if !isStandardMode, !isStandardSetup, listModel.collection.selectedProfile?.standardProfile == nil {
                Section {
                    Toggle(
                        "Interrupt Hermes by talking (headphones only)",
                        isOn: $interruptByTalking
                    )
                    .accessibilityIdentifier("interrupt-by-talking")
                } header: {
                    Text("Voice")
                } footer: {
                    Text("With Keep listening on, speaking while Hermes answers stops it, but only on headphones. Off: tap the orb to interrupt, so the TV or other people can't cut Hermes off.")
                }
                }
                #endif
                if !isStandardMode, !isStandardSetup, listModel.collection.selectedProfile?.standardProfile == nil,
                   let automaticDiagnostics {
                    AutomaticDiagnosticsSettings(reporter: automaticDiagnostics)
                }

                Section {
                    ShareLink(
                        item: DiagnosticsExport(journal: .shared),
                        preview: SharePreview("Hermes Relay diagnostics")
                    ) {
                        Label("Share diagnostics", systemImage: "stethoscope")
                    }
                    LabeledContent("Version", value: Self.appVersionLabel)
                        .foregroundStyle(HermesVisualTokens.secondaryInk)
                        .accessibilityIdentifier("app-version")
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("Connection events only: no messages, voice, or passwords. Send it to whoever is helping you.")
                }
                if let message = listModel.errorMessage {
                    Section { Text(message).foregroundStyle(HermesVisualTokens.unavailable) }
                }
            }
            .disabled(connectionChangeBlockedReason != nil || isReconfiguring)
            #if os(macOS)
            // The automatic macOS Form is an intrinsically sized column layout,
            // not a scrolling settings surface.
            .formStyle(.grouped)
            #endif
            .navigationTitle("Configure Relay")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showingDeviceDiscovery) {
                DeviceDiscoveryView(
                    client: deviceDiscoveryClient,
                    administrationClient: deviceAdministrationClient,
                    draftStore: deviceSetupDraftStore,
                    configurationStore: deviceConfigurationStore,
                    homeServiceClient: homeServiceClient
                )
            }
            #endif
            .sheet(isPresented: $showingHomeSetup) {
                if let homeLiveConfigurationStore,
                   let homeCredentialStore,
                   let homeClientFactory {
                    HomeLiveSetupView(
                        configurationStore: configurationStore,
                        credentialStore: homeCredentialStore,
                        liveConfigurationStore: homeLiveConfigurationStore,
                        homeClientFactory: homeClientFactory,
                        reconfigurationBlockedReason: currentBlockedReason,
                        beginReconfiguration: beginConnectionChange,
                        endReconfiguration: endConnectionChange,
                        onActivated: {
                            await onSaved()
                            if let editingProfileID {
                                await loadHomeAdminCredential(for: editingProfileID)
                            }
                        }
                    )
                } else {
                    Text("Home live setup is unavailable.")
                        .padding()
                }
            }
            .sheet(isPresented: $showingHomePairing) {
                if let homePairingCoordinator {
                    HomePairingView(
                        coordinator: homePairingCoordinator,
                        beginReconfiguration: beginConnectionChange,
                        endReconfiguration: endConnectionChange,
                        blockedReason: currentBlockedReason,
                        onReconfigurationFailure: {
                            await listModel.load()
                            await onSaved()
                        },
                        onPaired: {
                            await listModel.load()
                            await onSaved()
                        }
                    )
                    .disabled(connectionChangeBlockedReason != nil)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView("Loading configuration…")
                        .padding(20)
                        .relayPanel(cornerRadius: 16, fill: HermesVisualTokens.panel)
                }
            }
            .task {
                await load()
                await listModel.load()
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 640, minHeight: 320, idealHeight: 560)
        #endif
    }

    /// Marketing version and build number from the built app's Info.plist.
    private static let appVersionLabel: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }()

    @ViewBuilder
    private func validationMessage(for field: RelayConfigurationField) -> some View {
        if didAttemptValidation, let message = draft.validationErrors[field] {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(HermesVisualTokens.unavailable)
                .accessibilityIdentifier("relay-\(field.rawValue)-validation-error")
        }
    }

    private func modeLabel(for profile: RelayProfile) -> String {
        switch listModel.collection.transportMode(for: profile.id) {
        case .home: "HomeBridge"
        case .standard: "Standard Hermes"
        case .legacy: "Legacy relay"
        }
    }

    private func currentBlockedReason() -> String? {
        reconfigurationBlockedReason() ?? connectionChangeBlockedReason
    }

    @discardableResult
    private func allowReconfiguration() -> Bool {
        guard let reason = currentBlockedReason() else { return true }
        errorMessage = reason
        return false
    }

    private func beginConnectionChange() async -> Bool {
        guard allowReconfiguration(), !isReconfiguring else { return false }
        isReconfiguring = true
        guard await beginReconfiguration() else {
            isReconfiguring = false
            errorMessage = currentBlockedReason() ?? "Another connection change is already in progress."
            return false
        }
        return true
    }

    private func endConnectionChange() {
        endReconfiguration()
        isReconfiguring = false
    }

    private func chooseConnection(_ choice: NewConnectionChoice) async {
        guard await beginConnectionChange() else { return }
        defer { endConnectionChange() }
        setupChoice = choice
        showingHomePairing = choice == .home && homePairingCoordinator != nil
    }

    private func select(_ profile: RelayProfile) async {
        guard await beginConnectionChange() else { return }
        defer { endConnectionChange() }
        await listModel.select(id: profile.id)
        guard listModel.collection.selectedID == profile.id else { return }
        editingProfileID = profile.id
        setupChoice = nil
        if profile.standardProfile == nil {
            await loadHomeAdminCredential(for: profile.id)
            let token = try? await configurationStore.loadToken(for: profile.id)
            draft = RelayConfigurationDraft(profile: profile, hasStoredToken: token != nil, identity: .current())
        } else {
            homeAdminCredential = ""
            hasStoredHomeAdminCredential = false
        }
        didAttemptValidation = false
        focusedField = nil
        statusMessage = "\(profile.displayName) is now the active profile."
        // Selecting is the switch. Without this the app kept talking to the
        // previous relay until the user also pressed Save.
        await onSaved()
    }

    private func refreshHomeProfiles(pairingID: UUID) async {
        guard await beginConnectionChange() else { return }
        defer { endConnectionChange() }
        guard let homePairingCoordinator, refreshingHomeID == nil else { return }
        refreshingHomeID = pairingID
        homeRefreshMessages[pairingID] = nil
        defer { refreshingHomeID = nil }
        do {
            let summary = try await homePairingCoordinator.refresh(pairingID: pairingID)
            await listModel.load()
            await onSaved()
            homeRefreshMessages[pairingID] = summary.activationFailure ?? "Profiles updated."
        } catch {
            homeRefreshMessages[pairingID] = error.localizedDescription
            await listModel.load()
            await onSaved()
        }
    }

    private func unpair(pairingID: UUID) async throws {
        guard await beginConnectionChange() else {
            let reason = currentBlockedReason() ?? "Another connection change is already in progress."
            throw NSError(domain: "ConnectionChangeBlocked", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        defer { endConnectionChange() }
        let removedProfileIDs = Set(listModel.pairings.first { $0.id == pairingID }?.profiles.map(\.profileID) ?? [])
        let selectedBefore = listModel.collection.selectedID
        do {
            _ = try await listModel.unpair(pairingID: pairingID)
        } catch {
            await listModel.load()
            if let selectedBefore, !listModel.collection.profiles.contains(where: { $0.id == selectedBefore }) {
                await onSelectedProfileDeleted()
            } else {
                await onSaved()
            }
            throw error
        }
        if let editingProfileID, removedProfileIDs.contains(editingProfileID) {
            addProfile()
        }
        if let selectedBefore, removedProfileIDs.contains(selectedBefore) {
            await onSelectedProfileDeleted()
        }
    }

    private func delete(_ profile: RelayProfile) async {
        guard await beginConnectionChange() else { return }
        defer { endConnectionChange() }
        let wasSelected = listModel.collection.selectedID == profile.id
        let didDelete = await listModel.delete(id: profile.id)
        await listModel.load()
        guard didDelete || !listModel.collection.profiles.contains(where: { $0.id == profile.id }) else { return }
        if editingProfileID == profile.id {
            addProfile()
        }
        if wasSelected {
            await onSelectedProfileDeleted()
        }
    }

    /// Compose a new profile rather than editing the active one.
    private func addProfile() {
        guard allowReconfiguration() else { return }
        setupChoice = nil
        editingProfileID = nil
        draft = RelayConfigurationDraft(identity: .current())
        didAttemptValidation = false
        focusedField = nil
        statusMessage = nil
        homeAdminCredential = ""
        hasStoredHomeAdminCredential = false
        homeAdminHouseholdBinding = nil
        errorMessage = nil
    }

    private func load() async {
        guard !didLoad else { return }
        isLoading = true
        errorMessage = nil

        do {
            let profile = try await configurationStore.loadProfile()
            let token: String?
            if let profile, profile.standardProfile == nil {
                token = try await configurationStore.loadToken(for: profile.id)
            } else {
                token = nil
            }
            editingProfileID = profile?.id
            if let profile, profile.standardProfile == nil {
                await loadHomeAdminCredential(for: profile.id)
            } else {
                homeAdminCredential = ""
                hasStoredHomeAdminCredential = false
                homeAdminHouseholdBinding = nil
            }
            draft = RelayConfigurationDraft(
                profile: profile,
                hasStoredToken: token != nil,
                identity: .current()
            )
            didAttemptValidation = false
            focusedField = nil
            didLoad = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func save() async {
        guard isLegacyEditor, await beginConnectionChange() else { return }
        defer { endConnectionChange() }
        didAttemptValidation = true
        isSaving = true
        errorMessage = nil
        statusMessage = nil

        let validationErrors = draft.validationErrors
        if let firstInvalidField = RelayConfigurationField.allCases.first(where: {
            validationErrors[$0] != nil
        }) {
            focusedField = firstInvalidField
            isSaving = false
            return
        }

        focusedField = nil

        do {
            let original = listModel.collection.profiles.first { $0.id == editingProfileID }
            let candidate = try draft.makeProfile(id: original?.id)
            let endpointChanged = original.map { $0.endpoint != candidate.endpoint } ?? true
            if endpointChanged && draft.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorMessage = "Enter a new token when changing the endpoint. The old token will not be sent to a different endpoint."
                focusedField = .token
                isSaving = false
                return
            }
            let existingToken: String?
            if endpointChanged {
                existingToken = nil
            } else {
                existingToken = try await configurationStore.loadToken(for: candidate.id)
            }
            let connection = try draft.legacyConnection(original: original, storedToken: existingToken)

            guard allowReconfiguration() else { isSaving = false; return }
            try await configurationStore.saveLegacyConnection(connection.profile, token: connection.token)
            draft.hasStoredToken = true
            draft.token = ""
            editingProfileID = connection.profile.id
            await listModel.load()
            await onSaved()
            if original != nil && endpointChanged {
                statusMessage = "Saved as a new legacy connection. The earlier connection, credential, and history remain on this device; select it to view its transcript. Nothing was copied."
            } else {
                dismiss()
            }
        } catch let error as RelayConfigurationFormError {
            if case .tokenRequired = error {
                // The profile said a token existed, but Keychain no longer
                // has it. Reflect the actual state so the inline guidance
                // points at the field that needs attention.
                draft.hasStoredToken = false
                focusedField = .token
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isSaving = false
    }

    private func removeToken() async {
        guard isLegacyEditor, await beginConnectionChange() else { return }
        defer { endConnectionChange() }
        isSaving = true
        errorMessage = nil
        statusMessage = nil

        do {
            if let id = editingProfileID {
                try await configurationStore.deleteToken(for: id)
            }
            draft.hasStoredToken = false
            statusMessage = "The stored relay token was removed."
            await onSaved()
        } catch {
            errorMessage = error.localizedDescription
        }

        didAttemptValidation = false
        focusedField = nil

        isSaving = false
    }

    private func loadHomeAdminCredential(for profileID: UUID) async {
        guard let homeAdminCredentialStore,
              let homeLiveConfigurationStore else {
            homeAdminCredential = ""
            hasStoredHomeAdminCredential = false
            homeAdminHouseholdBinding = nil
            return
        }
        let route: HomeApprovedRoute?
        do {
            route = try await homeLiveConfigurationStore.approvedRoute(for: profileID)
        } catch {
            route = nil
        }
        homeAdminHouseholdBinding = route?.householdBinding
        guard let route else {
            homeAdminCredential = ""
            hasStoredHomeAdminCredential = false
            return
        }
        hasStoredHomeAdminCredential = await homeAdminCredentialStore.hasCredential(
            for: profileID,
            approvedRoute: route
        )
        homeAdminCredential = ""
    }

    private func saveHomeAdminCredential() async {
        guard allowReconfiguration(), !isStandardSetup else { return }
        guard let homeAdminCredentialStore,
              let profileID = editingProfileID else {
            errorMessage = "Save a Hermes Profile before adding the Home admin credential."
            return
        }

        guard let homeLiveConfigurationStore else {
            errorMessage = "Set up an approved Home route before saving the Home admin credential."
            return
        }
        let route: HomeApprovedRoute?
        do {
            route = try await homeLiveConfigurationStore.approvedRoute(for: profileID)
        } catch {
            route = nil
        }
        guard let route else {
            errorMessage = "Set up an approved Home route before saving the Home admin credential."
            return
        }

        isSavingHomeAdminCredential = true
        errorMessage = nil
        statusMessage = nil
        defer { isSavingHomeAdminCredential = false }

        do {
            let result = try await HomeAdminCredentialFormActions(
                store: homeAdminCredentialStore
            ).save(
                homeAdminCredential,
                for: profileID,
                approvedRoute: route
            )
            switch result {
            case .preserved:
                statusMessage = "The existing Home admin credential was kept."
            case .stored:
                homeAdminCredential = ""
                hasStoredHomeAdminCredential = true
                homeAdminHouseholdBinding = route.householdBinding
                statusMessage = "The Home admin credential was stored in Keychain."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeHomeAdminCredential() async {
        guard allowReconfiguration(), !isStandardSetup else { return }
        guard let homeAdminCredentialStore,
              let profileID = editingProfileID else { return }

        isSavingHomeAdminCredential = true
        errorMessage = nil
        statusMessage = nil
        defer { isSavingHomeAdminCredential = false }

        do {
            try await HomeAdminCredentialFormActions(
                store: homeAdminCredentialStore
            ).remove(for: profileID)
            homeAdminCredential = ""
            hasStoredHomeAdminCredential = false
            statusMessage = "The Home admin credential was removed."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
