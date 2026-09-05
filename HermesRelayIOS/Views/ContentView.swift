import SwiftUI

@MainActor
struct ContentView: View {
    @State private var store: ConversationStore
    @State private var voiceCoordinator: VoiceSessionCoordinator
    @State private var showingConfiguration = false
    @State private var showingHistory = false
    @State private var hudModel: AmbientHUDModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedField: FocusField?
    private let configurationStore: RelayConfigurationStore?
    private let activityStore: AudioActivityStore

    private enum FocusField: Hashable {
        case composer
    }

    init(
        store: ConversationStore = ConversationStore(),
        voiceCoordinator: VoiceSessionCoordinator? = nil,
        configurationStore: RelayConfigurationStore? = nil,
        activityStore providedActivityStore: AudioActivityStore? = nil
    ) {
        _store = State(initialValue: store)
        let activityStore = providedActivityStore ?? AudioActivityStore()
        self.activityStore = activityStore
        _hudModel = State(initialValue: AmbientHUDModel())
        if let voiceCoordinator {
            _voiceCoordinator = State(initialValue: voiceCoordinator)
        } else {
            let diagnostics = AudioPlaybackDiagnosticsFactory.make()
            _voiceCoordinator = State(initialValue: VoiceSessionCoordinator(
                store: store,
                input: AppleSpeechInput(activityReporter: activityStore),
                output: RecoveringAudioOutput(
                    liveOutput: AudioActivityReportingOutput(
                        wrapped: AppleAudioOutput(diagnostics: diagnostics),
                        reporter: activityStore
                    )
                ),
                diagnostics: diagnostics
            ))
        }
        self.configurationStore = configurationStore
    }

    private var canSend: Bool {
        store.connectionState.isConnected
            && !store.isSending
            && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ambientHUD
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomSurface
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task {
                hudModel.start(observing: activityStore)
            }
            .onDisappear {
                hudModel.stop()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task { await store.autoConnectIfNeeded() }
            }
        }
        .sheet(isPresented: $showingConfiguration) {
            if let configurationStore {
                RelayConfigurationView(configurationStore: configurationStore) {
                    await store.loadConfiguredClient()
                }
            }
        }
        .sheet(isPresented: $showingHistory) {
            TranscriptHistoryView(messages: store.messages)
        }
    }

    private var ambientHUD: some View {
        AmbientHUDView(
            presentation: AmbientHUDPresentation(
                voiceState: voiceCoordinator.state,
                activity: hudModel.snapshot,
                provisionalText: voiceCoordinator.provisionalText,
                messages: store.messages
            ),
            connectionState: store.connectionState,
            sessionStartedAt: store.sessionStartedAt,
            transcriptMessages: store.messages,
            provisionalText: voiceCoordinator.provisionalText,
            isResponseActive: store.isSending,
            activeAssistantID: store.activeAssistantID,
            voiceCoordinator: voiceCoordinator,
            speechTimings: voiceCoordinator.speechTimings,
            playbackDuration: voiceCoordinator.playbackDuration,
            playbackPosition: voiceCoordinator.playbackPosition,
            isPlaybackDurationFinal: voiceCoordinator.isPlaybackDurationFinal,
            hasTranscript: !store.messages.isEmpty,
            canConfigure: configurationStore != nil,
            unconfirmedTurnText: store.unconfirmedTurnText,
            onResendUnconfirmedTurn: {
                Task { await voiceCoordinator.resendUnconfirmedTurn() }
            },
            onConfigure: {
                showingConfiguration = true
            },
            onConnect: {
                Task { await store.connect() }
            },
            onShowHistory: {
                showingHistory = true
            }
        )
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let activityText = store.activityText {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(activityText)
                        .font(.footnote)
                        .lineLimit(1)
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }

            if let transientError = store.transientError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(transientError)
                        .font(.footnote)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        store.clearTransientError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Dismiss message")
                    .relayGlassButtonStyle()
                }
                .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Hermes…", text: $store.draft, axis: .vertical)
                    .focused($focusedField, equals: .composer)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
                    .lineLimit(1...3)
                    .submitLabel(.send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .onSubmit(sendDraftIfPossible)
                    .relayGlass(cornerRadius: 18, interactive: true)

                Button(action: sendDraftIfPossible) {
                    Image(systemName: "arrow.up")
                        .font(.headline.weight(.bold))
                        .frame(width: 20, height: 20)
                }
                .relayGlassProminentButtonStyle()
                .controlSize(.large)
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var voiceInterface: some View {
        VoiceControl(coordinator: voiceCoordinator)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var bottomSurface: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            HStack {
                GlassEffectContainer(spacing: 12) {
                    bottomControls
                }
                .padding(.vertical, 10)
                .frame(maxWidth: 760)
                .background {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular, in: .rect(cornerRadius: 28))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else {
            HStack {
                bottomControls
                    .frame(maxWidth: 760)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            if focusedField == nil {
                voiceInterface
            }
            composer
        }
    }

    private func sendDraftIfPossible() {
        guard canSend else { return }
        Task {
            await voiceCoordinator.sendDraft()
        }
    }
}

extension View {
    @ViewBuilder
    func relayGlass(
        cornerRadius: CGFloat,
        tint: Color? = nil,
        fallbackColor: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if let tint {
                if interactive {
                    self.glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: cornerRadius))
                } else {
                    self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
                }
            } else if interactive {
                self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else if let fallbackColor {
            self.background(fallbackColor, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func relayCircleGlass(tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if let tint {
                if interactive {
                    self.glassEffect(.regular.tint(tint).interactive(), in: .circle)
                } else {
                    self.glassEffect(.regular.tint(tint), in: .circle)
                }
            } else if interactive {
                self.glassEffect(.regular.interactive(), in: .circle)
            } else {
                self.glassEffect(.regular, in: .circle)
            }
        } else {
            self.background(.regularMaterial, in: Circle())
        }
    }

    @ViewBuilder
    func relayGlassButtonStyle() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func relayGlassProminentButtonStyle() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

#Preview("Conversation") {
    ContentView()
}

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
