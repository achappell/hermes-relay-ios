import SwiftUI

@MainActor
struct ContentView: View {
    @State private var store: ConversationStore
    @State private var voiceCoordinator: VoiceSessionCoordinator
    @State private var showingConfiguration = false
    private let configurationStore: RelayConfigurationStore?

    init(
        store: ConversationStore = ConversationStore(),
        voiceCoordinator: VoiceSessionCoordinator? = nil,
        configurationStore: RelayConfigurationStore? = nil
    ) {
        _store = State(initialValue: store)
        _voiceCoordinator = State(
            initialValue: voiceCoordinator ?? VoiceSessionCoordinator(
                store: store,
                input: AppleSpeechInput(),
                output: RecoveringAudioOutput(liveOutput: AppleAudioOutput())
            )
        )
        self.configurationStore = configurationStore
    }

    private var canSend: Bool {
        store.connectionState.isConnected
            && !store.isSending
            && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                connectionBanner
                transcript
                voiceInterface
                composer
            }
            .navigationTitle("Hermes Relay")
            .task {
                await store.loadConfiguredClient()
            }
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    configureButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    connectButton
                }
                #else
                ToolbarItem {
                    configureButton
                }
                ToolbarItem {
                    connectButton
                }
                #endif
            }
        }
        .sheet(isPresented: $showingConfiguration) {
            if let configurationStore {
                RelayConfigurationView(configurationStore: configurationStore) {
                    await store.loadConfiguredClient()
                }
            }
        }
    }

    @ViewBuilder
    private var configureButton: some View {
        if configurationStore != nil {
            Button {
                showingConfiguration = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Configure relay")
        }
    }

    private var connectButton: some View {
        Button(store.connectionState.isConnected ? "Connected" : "Connect") {
            Task { await store.connect() }
        }
        .disabled(store.connectionState == .connecting)
    }

    private var connectionBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.connectionState.isConnected ? .green : .secondary)
                .frame(width: 8, height: 8)
            Text(store.connectionState.label)
                .font(.subheadline.weight(.medium))
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if store.messages.isEmpty {
                    ContentUnavailableView(
                        "Conversation shell ready",
                        systemImage: "waveform.and.person.filled",
                        description: Text("Connect a configured Hermes relay to stream a text turn.")
                    )
                    .padding(.top, 72)
                } else {
                    ForEach(store.messages) { message in
                        MessageBubble(message: message)
                    }
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.06))
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let activityText = store.activityText {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(activityText)
                        .font(.footnote)
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }

            if let transientError = store.transientError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(transientError)
                        .font(.footnote)
                    Spacer()
                    Button {
                        store.clearTransientError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Dismiss message")
                }
                .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Hermes…", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                Button {
                    Task { await store.sendDraft() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
        }
        .padding()
        .background(.bar)
    }

    private var voiceInterface: some View {
        VStack(spacing: 8) {
            VoiceStatusView(state: voiceCoordinator.state)
            if !voiceCoordinator.provisionalText.isEmpty {
                Text(voiceCoordinator.provisionalText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
            }
            VoiceControl(coordinator: voiceCoordinator)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

#Preview {
    ContentView()
}

@MainActor
struct RelayConfigurationView: View {
    let configurationStore: RelayConfigurationStore
    let onSaved: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = RelayConfigurationDraft()
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
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Endpoint", text: $draft.endpoint)
                        .autocorrectionDisabled()
                    TextField("Client ID", text: $draft.clientID)
                        .autocorrectionDisabled()
                    TextField("Device ID", text: $draft.deviceID)
                        .autocorrectionDisabled()
                    TextField("Display name", text: $draft.displayName)
                } header: {
                    Text("Relay")
                } footer: {
                    Text("Use a ws:// or wss:// WebSocket endpoint.")
                }

                Section {
                    SecureField("Bearer token", text: $draft.token)
                        .autocorrectionDisabled()
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
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
            draft = RelayConfigurationDraft(profile: profile, hasStoredToken: token != nil)
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
            let profile = try draft.makeProfile()
            let existingToken = try await configurationStore.loadToken()
            let token = try draft.tokenToSave(existingToken: existingToken)

            try await configurationStore.saveProfile(profile)
            if !draft.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await configurationStore.saveToken(token)
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
            try await configurationStore.deleteToken()
            draft.hasStoredToken = false
            statusMessage = "The stored relay token was removed."
            await onSaved()
        } catch {
            errorMessage = error.localizedDescription
        }

        isSaving = false
    }
}
