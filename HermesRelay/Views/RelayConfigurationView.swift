import SwiftUI
import Observation

/// The profile list's state. The view stays a thin shell over this so the
/// select and delete behaviour is assertable without driving SwiftUI.
@MainActor
@Observable
final class RelayProfileListModel {
    private(set) var collection = RelayProfileCollection()
    /// App profiles bound to a Home pairing grant.
    private(set) var pairedProfileIDs: Set<UUID> = []
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
        if let homePairingCoordinator,
           let pairings = try? await homePairingCoordinator.allPairings() {
            pairedProfileIDs = Set(pairings.flatMap { $0.profiles.map(\.profileID) })
        } else {
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
                    try? FileManager.default.removeItem(
                        at: ConversationPersistenceFile.url(
                            in: conversationDirectory, for: id
                        )
                    )
                }
                await load()
                errorMessage = "The Profile was deleted, but its Home admin credential could not be removed. Remove it from Keychain before reusing this device."
                return true
            }
            if let conversationDirectory {
                try? FileManager.default.removeItem(
                    at: ConversationPersistenceFile.url(
                        in: conversationDirectory, for: id
                    )
                )
            }
            await load()
            if pairingCleanupFailed {
                errorMessage = "The Profile was deleted, but its Home pairing credential could not be removed. Remove it from Keychain before reusing this device."
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

@MainActor
struct HomeLiveSetupView: View {
    let configurationStore: RelayConfigurationStore
    let credentialStore: any HomeCredentialProvisioningStore
    let liveConfigurationStore: any HomeLiveConfigurationStore
    let homeClientFactory: any HomeBridgeSessionClientFactory
    let onActivated: @MainActor () async -> Void

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
        onActivated: @escaping @MainActor () async -> Void = {}
    ) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
        self.liveConfigurationStore = liveConfigurationStore
        self.homeClientFactory = homeClientFactory
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
            isActivating = true
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
        }

        isActivating = false
    }
}

@MainActor
struct RelayConfigurationView: View {
    let configurationStore: RelayConfigurationStore
    /// Live connection state, so the list can show which profile is actually
    /// connected rather than only which one is selected.
    let connectionState: ConnectionState
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
    let onSaved: @MainActor () async -> Void
    let onSelectedProfileDeleted: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: RelayConfigurationDraft
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var didLoad = false
    @State private var listModel: RelayProfileListModel
    @State private var showingDeviceDiscovery = false
    @State private var showingHomeSetup = false
    @State private var showingHomePairing = false
    @State private var homeAdminCredential = ""
    @State private var hasStoredHomeAdminCredential = false
    @State private var homeAdminHouseholdBinding: String?
    @State private var isSavingHomeAdminCredential = false
    @FocusState private var focusedField: RelayConfigurationField?
    @State private var didAttemptValidation = false
    /// Which saved profile the form is editing. Nil means the form is
    /// composing a new one, so saving must not overwrite the active profile.
    @State private var editingProfileID: UUID?

    init(
        configurationStore: RelayConfigurationStore,
        connectionState: ConnectionState = .disconnected,
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
        onSaved: @escaping @MainActor () async -> Void = {},
        onSelectedProfileDeleted: @escaping @MainActor () async -> Void = {}
    ) {
        self.configurationStore = configurationStore
        self.connectionState = connectionState
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
                                            listModel.pairedProfileIDs.contains(profile.id)
                                                ? "Paired with Home"
                                                : profile.endpoint.absoluteString
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
                        }

                        Button("Add profile") {
                            addProfile()
                        }
                        .disabled(isLoading || isSaving)
                    } header: {
                        Text("Saved profiles")
                    } footer: {
                        Text("The checked profile is the one Connect uses.")
                    }
                }

                #if os(iOS)
                Section {
                    Button {
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

                if homePairingCoordinator != nil {
                    Section {
                        Button {
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
                        Text("The Home credential is stored only in Keychain and renewed automatically.")
                    }
                }

                if homeLiveConfigurationStore != nil,
                   homeCredentialStore != nil,
                   homeClientFactory != nil {
                    Section {
                        Button {
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
                        onPaired: {
                            await listModel.load()
                            await onSaved()
                        }
                    )
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
    }

    @ViewBuilder
    private func validationMessage(for field: RelayConfigurationField) -> some View {
        if didAttemptValidation, let message = draft.validationErrors[field] {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(HermesVisualTokens.unavailable)
                .accessibilityIdentifier("relay-\(field.rawValue)-validation-error")
        }
    }

    private func select(_ profile: RelayProfile) async {
        await listModel.select(id: profile.id)
        editingProfileID = profile.id
        await loadHomeAdminCredential(for: profile.id)
        let token = try? await configurationStore.loadToken(for: profile.id)
        draft = RelayConfigurationDraft(
            profile: profile,
            hasStoredToken: token != nil,
            identity: .current()
        )
        didAttemptValidation = false
        focusedField = nil
        statusMessage = "\(profile.displayName) is now the active profile."
        // Selecting is the switch. Without this the app kept talking to the
        // previous relay until the user also pressed Save.
        await onSaved()
    }

    private func delete(_ profile: RelayProfile) async {
        let wasSelected = listModel.collection.selectedID == profile.id
        let didDelete = await listModel.delete(id: profile.id)
        guard didDelete else { return }
        if editingProfileID == profile.id {
            addProfile()
        }
        if wasSelected {
            await onSelectedProfileDeleted()
        }
    }

    /// Compose a new profile rather than editing the active one.
    private func addProfile() {
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
            let token = try await configurationStore.loadToken()
            editingProfileID = profile?.id
            if let profile {
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
            // Editing a saved profile keeps its identity so saving updates it;
            // composing a new one mints a fresh identity instead of
            // overwriting whichever profile happens to be active.
            let profile = try draft.makeProfile(id: editingProfileID)
            let existingToken = try await configurationStore.loadToken()
            let token = try draft.tokenToSave(existingToken: existingToken)

            try await configurationStore.saveProfile(profile)
            if !draft.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await configurationStore.saveToken(token, for: profile.id)
            }
            draft.hasStoredToken = true
            if editingProfileID == nil {
                try await configurationStore.selectProfile(id: profile.id)
            }
            editingProfileID = profile.id
            await listModel.load()
            await onSaved()
            dismiss()
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
