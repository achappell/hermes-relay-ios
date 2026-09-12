import SwiftUI
import Observation

/// The profile list's state. The view stays a thin shell over this so the
/// select and delete behaviour is assertable without driving SwiftUI.
@MainActor
@Observable
final class RelayProfileListModel {
    private(set) var collection = RelayProfileCollection()
    var errorMessage: String?

    private let configurationStore: RelayConfigurationStore
    /// Where per-profile conversations live, so deleting a profile takes its
    /// messages with it rather than leaving them readable on disk.
    private let conversationDirectory: URL?

    init(
        configurationStore: RelayConfigurationStore,
        conversationDirectory: URL? = nil
    ) {
        self.configurationStore = configurationStore
        self.conversationDirectory = conversationDirectory
    }

    func load() async {
        do {
            collection = try await configurationStore.loadCollection()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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
            if let conversationDirectory {
                try? FileManager.default.removeItem(
                    at: ConversationPersistenceFile.url(
                        in: conversationDirectory, for: id
                    )
                )
            }
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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
        self.onSaved = onSaved
        self.onSelectedProfileDeleted = onSelectedProfileDeleted
        _draft = State(initialValue: RelayConfigurationDraft(identity: .current()))
        _listModel = State(
            initialValue: RelayProfileListModel(
                configurationStore: configurationStore,
                conversationDirectory: conversationDirectory
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
                                        Text(profile.endpoint.absoluteString)
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
                    configurationStore: deviceConfigurationStore
                )
            }
            #endif
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
}
