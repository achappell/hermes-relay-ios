import SwiftUI

#if os(iOS)
import UIKit
#endif

/// The long-lived voice and lifecycle objects behind `ContentView`.
///
/// SwiftUI re-runs `ContentView.init` whenever the app body re-evaluates
/// (every scene phase change does, because `HermesRelayApp` reads
/// `scenePhase`). `@State` keeps only the first value it was given, so a stack
/// built in `init` leaves a fresh, never-used voice coordinator behind each
/// time, and a lifecycle coordinator held as a plain `let` ends up bound to
/// that orphan. On the 2026-10-05 device runs this made every `.background`
/// read "no reply in flight" from an unused coordinator, tear the shared
/// Home client and audio session down, and leave the real playback engine
/// running unattended. The stack is therefore built exactly once.
@MainActor
final class ContentViewRuntime {
    let activityStore: AudioActivityStore
    let voiceCoordinator: VoiceSessionCoordinator
    let lifecycleCoordinator: AppleLifecycleCoordinator

    init(
        store: ConversationStore,
        voiceCoordinator providedVoiceCoordinator: VoiceSessionCoordinator? = nil,
        activityStore providedActivityStore: AudioActivityStore? = nil,
        homeClientFactory: any HomeBridgeSessionClientFactory,
        homeClock: any HomeMonotonicClock,
        backgroundRetentionEnabled: Bool = AppleLifecycleCoordinator.platformSupportsBackgroundRetention,
        journal: DiagnosticsJournal = .shared
    ) {
        let activityStore = providedActivityStore ?? AudioActivityStore()
        self.activityStore = activityStore
        let voice: VoiceSessionCoordinator
        if let providedVoiceCoordinator {
            voice = providedVoiceCoordinator
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
            let recoveringOutput = RecoveringAudioOutput(
                liveOutput: AudioActivityReportingOutput(
                    wrapped: AppleAudioOutput(
                        diagnostics: diagnostics,
                        audioSessionCoordinator: audioSessionCoordinator
                    ),
                    reporter: activityStore
                )
            )
            voice = VoiceSessionCoordinator(
                store: store,
                input: speechInput,
                output: HomeAwareAudioOutput(
                    wrapped: recoveringOutput,
                    isHomeMode: { @MainActor [weak store] in store?.isHomeMode ?? false }
                ),
                diagnostics: diagnostics,
                handsFreeInput: handsFreeInput,
                clock: homeClock,
                audioSessionPolicy: audioSessionCoordinator,
                nowPlaying: NowPlayingController()
            )
        }
        self.voiceCoordinator = voice
        self.lifecycleCoordinator = AppleLifecycleCoordinator(
            store: store,
            voice: voice,
            homeClientFactory: homeClientFactory,
            clock: homeClock,
            backgroundRetentionEnabled: backgroundRetentionEnabled,
            journal: journal
        )
        journal.record("runtime created")
    }
}

/// Holds the runtime across `ContentView` re-initialisations. `@State` keeps
/// this cheap box, and the runtime is built on first use by whichever copy of
/// the view asks first.
@MainActor
final class ContentViewRuntimeBox {
    private var runtime: ContentViewRuntime?

    func resolve(_ make: @MainActor () -> ContentViewRuntime) -> ContentViewRuntime {
        if let runtime { return runtime }
        let made = make()
        runtime = made
        return made
    }
}

@MainActor
struct ContentView: View {
    @State private var store: ConversationStore
    @State private var runtimeBox = ContentViewRuntimeBox()
    @State private var showingConfiguration = false
    @State private var showingHistory = false
    @State private var showingHomeSessions = false
    @State private var scrollToOpenHomeClaimsOnPresent = false
    @State private var promptHistory = PromptHistory()
    @State private var hudModel: AmbientHUDModel
    @State private var pairingLinkRequest: HomePairingLinkRequest?
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedField: FocusField?
    private let configurationStore: RelayConfigurationStore?
    private let conversationDirectory: URL?
    private let deviceDiscoveryClient: any DeviceDiscoveryClient
    private let deviceAdministrationClient: any DeviceAdministrationClient
    private let deviceSetupDraftStore: any DeviceSetupDraftStore
    private let deviceConfigurationStore: any DeviceConfigurationStore
    private let homeServiceClient: (any HomeServiceClient)?
    private let runtimeFactory: @MainActor () -> ContentViewRuntime
    private let homeClientFactory: any HomeBridgeSessionClientFactory
    private let homeLiveConfigurationStore: (any HomeLiveConfigurationStore)?
    private let homeCredentialStore: (any HomeCredentialProvisioningStore)?
    private let homeAdminCredentialStore: (any HomeAdminCredentialStore)?
    private let homePairingCoordinator: HomeClientPairingCoordinator?
    private let pairingInbox: HomePairingLinkInbox?

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
        homeServiceClient: (any HomeServiceClient)? = nil,
        activityStore providedActivityStore: AudioActivityStore? = nil,
        homeClientFactory: any HomeBridgeSessionClientFactory = UnavailableHomeBridgeSessionClientFactory(),
        homeClaimProvider: (any HomeConversationClaimProvider)? = nil,
        homeLiveConfigurationStore: (any HomeLiveConfigurationStore)? = nil,
        homeCredentialStore: (any HomeCredentialProvisioningStore)? = nil,
        homeAdminCredentialStore: (any HomeAdminCredentialStore)? = nil,
        homePairingCoordinator: HomeClientPairingCoordinator? = nil,
        pairingInbox: HomePairingLinkInbox? = nil,
        homeClock: any HomeMonotonicClock = ContinuousHomeMonotonicClock()
    ) {
        _store = State(initialValue: store)
        store.configureHomeClientFactory(homeClientFactory, claimProvider: homeClaimProvider)
        _hudModel = State(initialValue: AmbientHUDModel())
        runtimeFactory = {
            ContentViewRuntime(
                store: store,
                voiceCoordinator: voiceCoordinator,
                activityStore: providedActivityStore,
                homeClientFactory: homeClientFactory,
                homeClock: homeClock
            )
        }
        self.configurationStore = configurationStore
        self.conversationDirectory = conversationDirectory
        self.deviceDiscoveryClient = deviceDiscoveryClient
        self.deviceAdministrationClient = deviceAdministrationClient
        self.deviceSetupDraftStore = deviceSetupDraftStore
        self.deviceConfigurationStore = deviceConfigurationStore
        self.homeServiceClient = homeServiceClient
        self.homeClientFactory = homeClientFactory
        self.homeLiveConfigurationStore = homeLiveConfigurationStore
        self.homeCredentialStore = homeCredentialStore
        self.homeAdminCredentialStore = homeAdminCredentialStore
        self.homePairingCoordinator = homePairingCoordinator
        self.pairingInbox = pairingInbox
    }

    private var runtime: ContentViewRuntime { runtimeBox.resolve(runtimeFactory) }
    private var voiceCoordinator: VoiceSessionCoordinator { runtime.voiceCoordinator }
    private var activityStore: AudioActivityStore { runtime.activityStore }
    private var lifecycleCoordinator: AppleLifecycleCoordinator { runtime.lifecycleCoordinator }

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

    /// The composer is a vertical `TextField`, which inserts Return as a
    /// newline instead of calling `onSubmit`. A single inserted newline is the
    /// Send key: this returns the draft without it. Pasted multi-line text is
    /// an edit, not a submission, and returns nil.
    static func draftSubmittedByReturn(from oldDraft: String, to newDraft: String) -> String? {
        guard newDraft.count == oldDraft.count + 1 else { return nil }
        let sharedPrefix = zip(oldDraft, newDraft).prefix { $0 == $1 }.count
        let insertedIndex = newDraft.index(newDraft.startIndex, offsetBy: sharedPrefix)
        guard newDraft[insertedIndex].isNewline else { return nil }
        var submitted = newDraft
        submitted.remove(at: insertedIndex)
        return submitted == oldDraft ? submitted : nil
    }

    var body: some View {
        NavigationStack {
            // The HUD fills the visible height between the top bar and the
            // bottom bar, compressing its orb and spacers to fit. It is never
            // pinned to that height: when even the compressed content is
            // taller (large Dynamic Type, a long Home status block, a wrapped
            // Profile name, the keyboard) the scroll view scrolls instead of
            // a fixed frame spilling the overflow symmetrically under the
            // Disconnect toolbar button and behind the bottom bar. The bottom
            // bar is a safe-area inset, so the last content scrolls fully
            // clear of it. The scroll view is always present — swapping it in
            // on focus counted as a scroll and dismissed the keyboard — and
            // it bounces only when its content overflows.
            GeometryReader { proxy in
                let isComposing = focusedField == .composer
                ScrollView {
                    ViewportFillLayout(viewportHeight: proxy.size.height) {
                        ambientHUD
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                // As in Messages: tapping the conversation while typing puts
                // the keyboard away (swiping down and sending also do).
                .simultaneousGesture(
                    TapGesture().onEnded {
                        if isComposing { focusedField = nil }
                    },
                    including: isComposing ? .all : .subviews
                )
            }
            .background {
                AmbientHUDBackdrop(
                    doorwayState: ConversationDoorwayState(
                        connectionState: store.connectionState,
                        profileName: store.activeProfileDisplayName
                    )
                )
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomSurface
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if store.isHomeMode, store.connectionState.isConnected {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Disconnect") {
                            Task { await store.disconnect() }
                        }
                        .disabled(store.isSending)
                        .accessibilityIdentifier("home-disconnect")
                    }
                }
            }
            .task {
                hudModel.start(observing: activityStore)
                if let conversationDirectory,
                   let activeID = try? await configurationStore?.loadProfile()?.id {
                    ConversationPersistenceMigrator.migrateLegacyConversation(
                        in: conversationDirectory,
                        to: activeID
                    )
                }
                _ = await lifecycleCoordinator.handle(.relaunch)
            }
            .onDisappear {
                hudModel.stop()
                Task {
                    _ = await lifecycleCoordinator.handleWindowDisappeared(
                        isSceneActive: scenePhase == .active
                    )
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                let input: AppleLifecycleInput
                switch newPhase {
                case .active: input = .active
                case .inactive: input = .inactive
                case .background: input = .background
                @unknown default: input = .inactive
                }
                DiagnosticsJournal.shared.record("app phase=\(input)")
                Task { _ = await lifecycleCoordinator.handle(input) }
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
                    deviceConfigurationStore: deviceConfigurationStore,
                    homeServiceClient: homeServiceClient,
                    homeLiveConfigurationStore: homeLiveConfigurationStore,
                    homeCredentialStore: homeCredentialStore,
                    homeAdminCredentialStore: homeAdminCredentialStore,
                    homeClientFactory: homeClientFactory,
                    homePairingCoordinator: homePairingCoordinator
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
        .sheet(isPresented: $showingHomeSessions) {
            HomeSessionsView(
                store: store,
                scrollToOpenClaims: scrollToOpenHomeClaimsOnPresent
            )
            .onDisappear { scrollToOpenHomeClaimsOnPresent = false }
        }
        .onChange(of: store.activeProfileID) {
            // Recent prompts belong to the Profile they were typed in.
            promptHistory = PromptHistory()
        }
        .onChange(of: pairingInbox?.pendingLink, initial: true) { _, link in
            guard let link else { return }
            pairingInbox?.pendingLink = nil
            pairingLinkRequest = HomePairingLinkRequest(url: link)
        }
        .sheet(item: $pairingLinkRequest) { request in
            if let homePairingCoordinator {
                HomePairingView(
                    coordinator: homePairingCoordinator,
                    initialLink: request.url,
                    onPaired: {
                        await store.switchToSelectedProfile()
                    }
                )
            } else {
                Text("Home pairing is unavailable.")
                    .padding()
            }
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
            unconfirmedTurnText: store.unresolvedTurnTextForDisplay,
            onResendUnconfirmedTurn: {
                Task { await voiceCoordinator.resendUnconfirmedTurn() }
            },
            canContinueWithoutResendingHomeTurn: store.canContinueWithoutResendingHomeTurn,
            onContinueWithoutResendingHomeTurn: {
                Task { await store.continueWithoutResendingHomeTurn() }
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
            settingsURL: applicationSettingsURL,
            homeBridgeState: store.isHomeMode ? store.homeBridgeState : nil,
            homeRouteState: store.isHomeMode ? store.homeRouteState : nil,
            homeTurnDeliveryState: store.isHomeMode ? store.homeTurnDeliveryState : nil,
            homeAudioState: store.isHomeMode ? store.homeAudioState : nil,
            homeTimingCapability: store.isHomeMode ? .absent : nil,
            pendingHomePromptKind: store.pendingHomePrompt?.prompt.kind,
            homeCommandEventCount: store.homeCommandEvents.count,
            homeSessionTitle: store.homeSession?.title,
            onShowSessions: (store.supportsHomeSessions || store.canManageOpenHomeClaims)
                ? {
                    scrollToOpenHomeClaimsOnPresent = store.shouldOfferManageOpenHomeClaims
                    showingHomeSessions = true
                }
                : nil
        )
    }

    /// One labelled button replaces the ▲▼ arrows (IOS-UX-F5). Choosing a
    /// prompt fills the composer to edit or send; it never sends by itself.
    private var recentPromptsMenu: some View {
        Menu {
            Section("Recent prompts") {
                ForEach(promptHistory.recent(), id: \.self) { prompt in
                    Button {
                        store.draft = prompt
                        focusedField = .composer
                    } label: {
                        Text(prompt).lineLimit(1)
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .frame(width: 16, height: 16)
                .foregroundStyle(HermesVisualTokens.secondaryInk)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Recent prompts")
        .accessibilityIdentifier("recent-prompts")
        .relayGlassButtonStyle()
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

            if store.canStartNewHomeConversation {
                Button {
                    Task { await store.startNewHomeConversation() }
                } label: {
                    Label("Start new conversation", systemImage: "plus.bubble")
                }
                .relayGlassButtonStyle()
                .accessibilityIdentifier("home-start-new-conversation")
            }

            if store.canManageOpenHomeClaims {
                Button {
                    scrollToOpenHomeClaimsOnPresent = true
                    showingHomeSessions = true
                } label: {
                    Label("Manage open conversations", systemImage: "rectangle.stack.badge.person.crop")
                }
                .relayGlassButtonStyle()
                .disabled(store.isClosingOpenHomeClaims)
                .accessibilityIdentifier("home-manage-open-conversations")
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
                if !promptHistory.isEmpty {
                    recentPromptsMenu
                }

                TextField("Message Hermes…", text: $store.draft, axis: .vertical)
                    .focused($focusedField, equals: .composer)
                    .textFieldStyle(.plain)
                    .foregroundStyle(HermesVisualTokens.primaryInk)
                    .lineLimit(1...3)
                    .submitLabel(.send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .onSubmit(submitFromReturnKey)
                    .onChange(of: store.draft) { oldDraft, newDraft in
                        guard let submitted = Self.draftSubmittedByReturn(
                            from: oldDraft,
                            to: newDraft
                        ) else { return }
                        store.draft = submitted
                        submitFromReturnKey()
                    }
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

    /// The bottom surface is for typing. Talking, sending, interrupting and
    /// hands-free live with the voice orb (IOS-UX-F5).
    private var bottomControls: some View {
        VStack(spacing: 0) {
            composer
        }
    }

    /// Return always leaves the keyboard: it sends when it can, and otherwise
    /// dismisses so the send button and any notice behind it are reachable.
    private func submitFromReturnKey() {
        guard canSend else {
            focusedField = nil
            return
        }
        sendDraftIfPossible()
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
