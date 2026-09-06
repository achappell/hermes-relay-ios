import SwiftUI

@MainActor
struct RelayConfigurationView: View {
    let configurationStore: RelayConfigurationStore
    let onSaved: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: RelayConfigurationDraft
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var didLoad = false

    init(
        configurationStore: RelayConfigurationStore,
        onSaved: @escaping @MainActor () async -> Void = {}
    ) {
        self.configurationStore = configurationStore
        self.onSaved = onSaved
        _draft = State(initialValue: RelayConfigurationDraft(identity: .current()))
    }

    var body: some View {
        NavigationStack {
            Form {
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
            .overlay {
                if isLoading {
                    ProgressView("Loading configuration…")
                        .padding(20)
                        .relayGlass(cornerRadius: 20)
                }
            }
            .task {
                await load()
            }
        }
    }

    private func load() async {
        guard !didLoad else { return }
        isLoading = true
        errorMessage = nil

        do {
            let profile = try await configurationStore.loadProfile()
            let token = try await configurationStore.loadToken()
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
            // Editing the active profile keeps its identity, so saving
            // updates it instead of creating a duplicate alongside it.
            let editingID = try await configurationStore.loadProfile()?.id
            let profile = try draft.makeProfile(id: editingID)
            let existingToken = try await configurationStore.loadToken()
            let token = try draft.tokenToSave(existingToken: existingToken)

            try await configurationStore.saveProfile(profile)
            if !draft.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await configurationStore.saveToken(token, for: profile.id)
            }
            draft.hasStoredToken = true
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
            if let id = try await configurationStore.loadProfile()?.id {
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
