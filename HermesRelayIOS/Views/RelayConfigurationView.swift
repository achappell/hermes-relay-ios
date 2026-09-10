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

    func delete(id: UUID) async {
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
        } catch {
            errorMessage = error.localizedDescription
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
    let onSaved: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: RelayConfigurationDraft
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var didLoad = false
    @State private var listModel: RelayProfileListModel
    @State private var showingDeviceDiscovery = false
    /// Which saved profile the form is editing. Nil means the form is
    /// composing a new one, so saving must not overwrite the active profile.
    @State private var editingProfileID: UUID?

    init(
        configurationStore: RelayConfigurationStore,
        connectionState: ConnectionState = .disconnected,
        conversationDirectory: URL? = nil,
        deviceDiscoveryClient: any DeviceDiscoveryClient = UnavailableDeviceDiscoveryClient(),
        onSaved: @escaping @MainActor () async -> Void = {}
    ) {
        self.configurationStore = configurationStore
        self.connectionState = connectionState
        self.conversationDirectory = conversationDirectory
        self.deviceDiscoveryClient = deviceDiscoveryClient
        self.onSaved = onSaved
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
                                            .foregroundStyle(.secondary)
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
                                            connectionState.isConnected ? .green : .secondary
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
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Household Devices")
                }
                #endif

                Section {
                    TextField("Endpoint", text: $draft.endpoint)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    TextField("Client ID", text: $draft.clientID)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                    TextField("Device ID", text: $draft.deviceID)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                    TextField("Display name", text: $draft.displayName)
                } header: {
                    Text("Relay")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use a ws:// or wss:// WebSocket endpoint.")
                        Text("Client and device IDs start from this device’s name and remain editable.")
                    }
                }

                Section {
                    SecureField("Bearer token", text: $draft.token)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                    if draft.hasStoredToken {
                        Label(
                            "A token is stored securely. Leave this blank to keep it.",
                            systemImage: "checkmark.shield"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("The token is stored in Keychain and is never written to the profile file.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Credentials")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if let statusMessage {
                    Section {
                        Label(statusMessage, systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
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
                DeviceDiscoveryView(client: deviceDiscoveryClient)
            }
            #endif
            .overlay {
                if isLoading {
                    ProgressView("Loading configuration…")
                        .padding(20)
                        .relayGlass(cornerRadius: 20)
                }
            }
            .task {
                await load()
                await listModel.load()
            }
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
        statusMessage = "\(profile.displayName) is now the active profile."
        // Selecting is the switch. Without this the app kept talking to the
        // previous relay until the user also pressed Save.
        await onSaved()
    }

    private func delete(_ profile: RelayProfile) async {
        await listModel.delete(id: profile.id)
        if editingProfileID == profile.id {
            addProfile()
        }
    }

    /// Compose a new profile rather than editing the active one.
    private func addProfile() {
        editingProfileID = nil
        draft = RelayConfigurationDraft(identity: .current())
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
            didLoad = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        statusMessage = nil

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

        isSaving = false
    }
}
