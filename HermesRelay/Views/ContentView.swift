import SwiftUI

#if os(iOS)
import UIKit
#endif

@MainActor
struct ContentView: View {
    @State private var store: ConversationStore
    @State private var voiceCoordinator: VoiceSessionCoordinator
    @State private var showingConfiguration = false
    @State private var showingHistory = false
    @State private var promptHistory = PromptHistory()
    @State private var hudModel: AmbientHUDModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedField: FocusField?
    private let configurationStore: RelayConfigurationStore?
    private let conversationDirectory: URL?
    private let deviceDiscoveryClient: any DeviceDiscoveryClient
    private let deviceAdministrationClient: any DeviceAdministrationClient
    private let deviceSetupDraftStore: any DeviceSetupDraftStore
    private let deviceConfigurationStore: any DeviceConfigurationStore
    private let activityStore: AudioActivityStore

    private enum FocusField: Hashable {
        case composer
    }

    init(
        store: ConversationStore = ConversationStore(),
        voiceCoordinator: VoiceSessionCoordinator? = nil,
        configurationStore: RelayConfigurationStore? = nil,
        conversationDirectory: URL? = nil,
        deviceDiscoveryClient: any DeviceDiscoveryClient = UnavailableDeviceDiscoveryClient(),
        deviceAdministrationClient: any DeviceAdministrationClient = UnavailableDeviceAdministrationClient(),
        deviceSetupDraftStore: any DeviceSetupDraftStore = NoopDeviceSetupDraftStore(),
        deviceConfigurationStore: any DeviceConfigurationStore = NoopDeviceConfigurationStore(),
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
            let audioSessionCoordinator = AppleAudioSessionCoordinator()
            let speechInput = AppleSpeechInput(
                activityReporter: activityStore,
                audioSessionCoordinator: audioSessionCoordinator
            )
            #if os(iOS)
            let handsFreeInput: (any HandsFreeInput)? = SpeechBackedHandsFreeInput(
                speechInput: speechInput,
                activityStore: activityStore
            )
            #else
            let handsFreeInput: (any HandsFreeInput)? = nil
            #endif
            _voiceCoordinator = State(initialValue: VoiceSessionCoordinator(
                store: store,
                input: speechInput,
                output: RecoveringAudioOutput(
                    liveOutput: AudioActivityReportingOutput(
                        wrapped: AppleAudioOutput(
                            diagnostics: diagnostics,
                            audioSessionCoordinator: audioSessionCoordinator
                        ),
                        reporter: activityStore
                    )
                ),
                diagnostics: diagnostics,
                handsFreeInput: handsFreeInput
            ))
        }
        self.configurationStore = configurationStore
        self.conversationDirectory = conversationDirectory
        self.deviceDiscoveryClient = deviceDiscoveryClient
        self.deviceAdministrationClient = deviceAdministrationClient
        self.deviceSetupDraftStore = deviceSetupDraftStore
        self.deviceConfigurationStore = deviceConfigurationStore
    }

    private var canSend: Bool {
        store.connectionState.isConnected
            && !store.isSending
            && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showsCachedDraftNotice: Bool {
        !store.connectionState.isConnected
            && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var cachedDraftNoticeText: String {
        if configurationStore != nil, store.activeProfileDisplayName == nil {
            return "Draft saved locally. Configure a relay before sending."
        }
        return "Draft saved locally. Connect before sending."
    }

    private var applicationSettingsURL: URL? {
        #if os(iOS)
        return URL(string: UIApplication.openSettingsURLString)
        #else
        return nil
        #endif
    }

    static func shouldShowVoiceInterface(
        isConnected: Bool = true,
        isComposerFocused: Bool,
        state: VoiceState,
        isHandsFreeArmed: Bool = false
    ) -> Bool {
        guard isConnected else { return false }
        return VoiceControlInteractionPolicy.isVisible(
            isComposerFocused: isComposerFocused,
            state: state,
            isHandsFreeArmed: isHandsFreeArmed
        )
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
                Task { await voiceCoordinator.disableHandsFree() }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await store.autoConnectIfNeeded() }
                } else {
                    Task { await voiceCoordinator.disableHandsFree() }
                }
            }
            .onChange(of: store.connectionState) { _, newState in
                guard newState != .connected else { return }
                Task {
                    await voiceCoordinator.cancelCapture()
                    await voiceCoordinator.disableHandsFree()
                }
            }
        }
        .sheet(isPresented: $showingConfiguration) {
            if let configurationStore {
                RelayConfigurationView(
                    configurationStore: configurationStore,
                    connectionState: store.connectionState,
                    conversationDirectory: conversationDirectory,
                    deviceDiscoveryClient: deviceDiscoveryClient,
                    deviceAdministrationClient: deviceAdministrationClient,
                    deviceSetupDraftStore: deviceSetupDraftStore,
                    deviceConfigurationStore: deviceConfigurationStore
                ) {
                    // The selected profile may have changed, so reconnect to
                    // whichever relay is now active rather than only reloading
                    // credentials for the old one.
                    await store.switchToSelectedProfile()
                } onSelectedProfileDeleted: {
                    await store.clearSelectedProfile()
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
                messages: store.messages,
                isHandsFreeArmed: voiceCoordinator.isHandsFreeArmed
            ),
            connectionState: store.connectionState,
            sessionStartedAt: store.sessionStartedAt,
            profileName: store.activeProfileDisplayName,
            transcriptMessages: store.messages,
            provisionalText: voiceCoordinator.provisionalText,
            isResponseActive: voiceCoordinator.state.isResponseActive,
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
            },
            settingsURL: applicationSettingsURL
        )
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if showsCachedDraftNotice {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                    Text(cachedDraftNoticeText)
                        .font(.footnote)
                    Spacer()
                }
                .foregroundStyle(HermesVisualTokens.secondaryInk)
                .accessibilityIdentifier("cached-draft-notice")
            }

            if let activityText = store.activityText {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(activityText)
                        .font(.footnote)
                        .lineLimit(1)
                    Spacer()
                }
                .foregroundStyle(HermesVisualTokens.secondaryInk)
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
                .foregroundStyle(HermesVisualTokens.secondaryInk)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    if let previous = promptHistory.previous(currentDraft: store.draft) {
                        store.draft = previous
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 16, height: 16)
                }
                .disabled(promptHistory.isEmpty)
                .accessibilityLabel("Previous prompt")
                .relayGlassButtonStyle()

                Button {
                    if let next = promptHistory.next() {
                        store.draft = next
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 16, height: 16)
                }
                .disabled(promptHistory.isEmpty)
                .accessibilityLabel("Next prompt")
                .relayGlassButtonStyle()

                TextField("Message Hermes…", text: $store.draft, axis: .vertical)
                    .focused($focusedField, equals: .composer)
                    .textFieldStyle(.plain)
                    .foregroundStyle(HermesVisualTokens.primaryInk)
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
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular, in: .rect(cornerRadius: 24))
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
            .background(HermesVisualTokens.consoleSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            if Self.shouldShowVoiceInterface(
                isConnected: store.connectionState.isConnected,
                isComposerFocused: focusedField != nil,
                state: voiceCoordinator.state,
                isHandsFreeArmed: voiceCoordinator.isHandsFreeArmed
            ) {
                voiceInterface
            }
            composer
        }
    }

    private func sendDraftIfPossible() {
        guard canSend else { return }
        promptHistory.record(store.draft)
        focusedField = nil
        Task {
            await voiceCoordinator.sendDraft()
        }
    }
}

extension View {
    /// A structural panel for explanatory, transcript, and recovery content.
    /// Glass remains reserved for controls and the grouped composer surface.
    func relayPanel(
        cornerRadius: CGFloat = 16,
        fill: Color = HermesVisualTokens.panel
    ) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(HermesVisualTokens.hairline, lineWidth: 0.5)
            }
    }

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
        .preferredColorScheme(.dark)
}

#Preview("Conversation — Light adaptation") {
    ContentView()
        .preferredColorScheme(.light)
}
