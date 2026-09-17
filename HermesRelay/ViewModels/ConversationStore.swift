import Foundation
import Observation

@MainActor
@Observable
final class ConversationStore {
    private var client: any HermesSessionClient
    private let configurationStore: RelayConfigurationStore?
    private let socketFactory: any WebSocketConnectionFactory
    private var persistence: (any ConversationPersistence)?
    /// Resolves the conversation store for a profile. Conversations belong to
    /// a relay, so switching profiles switches the file behind them.
    private let makePersistence: (@Sendable (UUID) -> any ConversationPersistence)?
    private let now: @Sendable () -> Date
    private let reconnectPolicy: ReconnectPolicy
    private let sleep: @Sendable (UInt64) async -> Void
    private var homeClientFactory: (any HomeBridgeSessionClientFactory)?
    private var homeClaimProvider: (any HomeConversationClaimProvider)?
    private let homeClock: any HomeMonotonicClock
    private let homeOperationDeadlines: HomeOperationDeadlines
    private let homeTurnAudioDeadlines: HomeTurnAudioDeadlines
    private var homeClient: (any HomeBridgeSessionClient)?
    private var homeClaim: HomeConversationClaim?
    private var homeConversationBinding: HomeConversationBinding?
    private var homeTurnBinding: HomeTurnBinding?
    private var homeRecovery: PersistedHomeRecovery?
    private var homeEventTask: Task<Void, Never>?
    private var homeTurnWaiters: [CheckedContinuation<Bool, Never>] = []
    private var homeAudioTerminalWaiter: CheckedContinuation<Void, Never>?
    private var homeTurnResult: Bool?
    private var homeEventHandler: (@MainActor @Sendable (HermesEvent) async -> Void)?
    private var homeNormalizer = HermesEventNormalizer()
    private var homeControlTerminal = false
    private var homeAudioTerminal = true
    private var homeAudioTerminalProcessing = false
    private var homeAudioRequested = false
    private var homeControlTimeoutTask: Task<Void, Never>?
    private var homeAudioStartTimeoutTask: Task<Void, Never>?
    private var homeAudioTimeoutTask: Task<Void, Never>?
    private(set) var homeJoinTimeout: HomeTurnJoinTimeout?
    private var homeOperationsSuppressed = false
    private var activeTurnText: String?

    var connectionState: ConnectionState = .disconnected
    var sessionMetadata: SessionMetadata?
    var sessionStartedAt: Date?
    private(set) var activeProfileID: UUID?
    private(set) var activeProfileDisplayName: String?
    var messages: [TranscriptMessage] = []
    var draft = ""
    var transientError: String?
    var activityText: String?
    var isSending = false
    var unconfirmedTurnText: String?
    private(set) var homeBridgeState: HomeBridgeState = .unconfigured
    private(set) var homeRouteState = HomeRouteState(
        status: .unattempted,
        identity: nil,
        failure: nil
    )
    private(set) var homeTurnDeliveryState: HomeTurnDeliveryState = .idle
    private(set) var homeAudioState: HomeAudioState = .notRequested
    private(set) var pendingHomePrompt: HomePendingStructuredPrompt?
    private(set) var homeCommandEvents: [HomeCommandEvent] = []
    private(set) var isLifecycleActive = true

    var isHomeMode: Bool { transportMode == .home }

    private var transportMode: AppleTransportMode = .legacy

    /// A turn may begin only from a connection that completed the Hermes
    /// handshake. `connectionState` alone is deliberately insufficient: the
    /// metadata is the proof that `hello_ack` was accepted.
    var verifiedTurnBinding: HermesTurnBinding? {
        guard connectionState.isConnected, !homeOperationsSuppressed else { return nil }
        if let homeConversationBinding, transportMode == .home {
            return HermesTurnBinding(
                profileID: activeProfileID,
                homeConversation: homeConversationBinding,
                turn: homeTurnBinding
            )
        }
        guard let sessionMetadata, let sessionID = sessionMetadata.sessionID else { return nil }
        return HermesTurnBinding(
            profileID: activeProfileID,
            sessionID: sessionID
        )
    }

    var turnUnavailableMessage: String {
        if configurationStore != nil, activeProfileDisplayName == nil {
            return "Select a Hermes Profile before starting a voice turn."
        }
        return "Connect to the Hermes relay before starting a voice turn."
    }

    private(set) var activeAssistantID: UUID?
    private var turnCompleted = false
    private var didAttemptAutomaticConnection = false
    // A closed stream can still deliver already-buffered events. Generation
    // invalidation keeps an interrupted turn from contaminating the next one.
    private var nextTurnGeneration: UInt64 = 0
    private var activeTurnGeneration: UInt64?
    private var interruptedTurnGeneration: UInt64?
    private var interruptionConfirmedTurnGeneration: UInt64?
    // Recovery from an unexpected transport loss runs as a single task. A
    // second loss reported while it is running is the same outage, not a new
    // one, so it must not stack a second backoff ladder.
    private var reconnectTask: Task<Void, Never>?
    private var isExpectedDisconnect = false

    init(
        client: any HermesSessionClient = UnavailableHermesSessionClient(),
        configurationStore: RelayConfigurationStore? = nil,
        socketFactory: any WebSocketConnectionFactory = URLSessionWebSocketConnectionFactory(),
        persistence: (any ConversationPersistence)? = nil,
        makePersistence: (@Sendable (UUID) -> any ConversationPersistence)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        reconnectPolicy: ReconnectPolicy = .default,
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
        homeClientFactory: (any HomeBridgeSessionClientFactory)? = nil,
        homeClaimProvider: (any HomeConversationClaimProvider)? = nil,
        homeClock: any HomeMonotonicClock = ContinuousHomeMonotonicClock(),
        homeOperationDeadlines: HomeOperationDeadlines = .default,
        homeTurnAudioDeadlines: HomeTurnAudioDeadlines = .default
    ) {
        self.client = client
        self.configurationStore = configurationStore
        self.socketFactory = socketFactory
        self.persistence = persistence
        self.makePersistence = makePersistence
        self.now = now
        self.reconnectPolicy = reconnectPolicy
        self.sleep = sleep
        self.homeClientFactory = homeClientFactory
        self.homeClaimProvider = homeClaimProvider
        self.homeClock = homeClock
        self.homeOperationDeadlines = homeOperationDeadlines
        self.homeTurnAudioDeadlines = homeTurnAudioDeadlines
    }

    func configureHomeClientFactory(
        _ factory: any HomeBridgeSessionClientFactory,
        claimProvider: (any HomeConversationClaimProvider)? = nil
    ) {
        homeClientFactory = factory
        if let claimProvider { homeClaimProvider = claimProvider }
    }

    func loadPersistedConversation() async {
        guard let persistence else { return }

        do {
            let conversation = try await persistence.load()
            messages = conversation.messages
            draft = conversation.draft
            unconfirmedTurnText = conversation.unconfirmedTurnText
            homeRecovery = conversation.homeRecovery
            if let recovery = conversation.homeRecovery {
                let recoveryText = conversation.unconfirmedTurnText
                    ?? messages.last(where: { $0.role == .user })?.text
                    ?? ""
                let recoveryBinding = HomeTurnBinding(
                    conversationHandle: recovery.conversationHandle,
                    turnID: recovery.turnID ?? "unconfirmed",
                    correlationID: recovery.correlationID ?? "unconfirmed"
                )
                let persistedTurn: HomeTurnBinding? = if let turnID = recovery.turnID,
                                                        let correlationID = recovery.correlationID {
                    HomeTurnBinding(
                        conversationHandle: recovery.conversationHandle,
                        turnID: turnID,
                        correlationID: correlationID
                    )
                } else {
                    nil
                }
                homeTurnBinding = persistedTurn
                if recovery.deliveryState == .awaitingAcceptance {
                    homeRecovery = PersistedHomeRecovery(
                        profileID: recovery.profileID,
                        endpoint: recovery.endpoint,
                        route: recovery.route,
                        householdBinding: recovery.householdBinding,
                        conversationHandle: recovery.conversationHandle,
                        turnID: recovery.turnID,
                        correlationID: recovery.correlationID,
                        submissionAttemptID: recovery.submissionAttemptID,
                        resumeCursor: recovery.resumeCursor,
                        deliveryState: .uncertain,
                        updatedAt: now()
                    )
                    unconfirmedTurnText = recoveryText
                    homeTurnDeliveryState = .uncertain(
                        recovery.turnID == nil ? nil : recoveryBinding
                    )
                    try? await persistence.save(
                        PersistedConversation(
                            messages: messages,
                            draft: draft,
                            unconfirmedTurnText: unconfirmedTurnText,
                            homeRecovery: homeRecovery
                        )
                    )
                } else if recovery.deliveryState == .accepted {
                    if let persistedTurn {
                        homeTurnDeliveryState = .accepted(persistedTurn)
                    } else {
                        homeTurnDeliveryState = .uncertain(nil)
                    }
                    unconfirmedTurnText = conversation.unconfirmedTurnText
                } else {
                    homeTurnDeliveryState = .uncertain(
                        persistedTurn
                    )
                    unconfirmedTurnText = recoveryText
                }
            }
            activeAssistantID = nil
        } catch {
            transientError = "The saved conversation could not be restored."
        }
    }

    @discardableResult
    func loadConfiguredClient() async -> Bool {
        guard let configurationStore else { return false }

        do {
            guard let profile = try await configurationStore.loadProfile() else {
                activeProfileID = nil
                activeProfileDisplayName = nil
                transientError = "Configure a Hermes relay profile before connecting."
                return false
            }
            activeProfileID = profile.id
            activeProfileDisplayName = profile.displayName
            if let makePersistence {
                persistence = makePersistence(profile.id)
            }

            transportMode = try await configurationStore.transportMode(for: profile.id)
            if transportMode == .home {
                homeOperationsSuppressed = false
                homeConversationBinding = nil
                if homeRecovery == nil {
                    homeTurnBinding = nil
                    homeTurnDeliveryState = .idle
                }
                guard let homeClaimProvider,
                      let claim = try await homeClaimProvider.conversationClaim(for: profile.id) else {
                    homeClaim = nil
                    homeClient = nil
                    homeBridgeState = .unavailable(
                        .home(code: .authorizationUnavailable, phase: .lifecycle)
                    )
                    transientError = "Home pairing is unavailable for this Hermes Profile."
                    return false
                }
                homeClaim = claim
                homeRouteState = HomeRouteState(
                    status: .unattempted,
                    identity: claim.approvedRoute.identity,
                    failure: nil
                )
                homeClient = (homeClientFactory ?? UnavailableHomeBridgeSessionClientFactory())
                    .make(profileID: profile.id, mode: .home)
                homeBridgeState = .disconnected(
                    .home(code: .transportUnavailable, phase: .lifecycle)
                )
                sessionMetadata = nil
                sessionStartedAt = nil
                transientError = nil
                didAttemptAutomaticConnection = false
                return true
            }

            guard let token = try await configurationStore.loadToken() else {
                transientError = "Add a Hermes relay token before connecting."
                return false
            }
            client = URLSessionHermesSessionClient(
                profile: profile,
                token: token,
                socketFactory: socketFactory,
                onTransportDisconnected: { @MainActor [weak self] in
                    self?.handleUnexpectedTransportLoss()
                }
            )
            homeClient = nil
            homeClaim = nil
            homeConversationBinding = nil
            homeTurnBinding = nil
            homeBridgeState = .unconfigured
            transientError = nil
            return true
        } catch {
            transientError = error.localizedDescription
            return false
        }
    }

    func isCurrentTurnBinding(_ binding: HermesTurnBinding) -> Bool {
        guard connectionState.isConnected, !homeOperationsSuppressed else { return false }
        guard binding.profileID == nil || binding.profileID == activeProfileID else { return false }
        if let conversation = binding.homeConversation {
            guard let current = homeConversationBinding, current == conversation else { return false }
            if let expectedTurn = binding.homeTurn {
                return homeTurnBinding == expectedTurn
            }
            return true
        }
        return verifiedTurnBinding == binding
    }

    func autoConnectIfNeeded() async {
        guard isLifecycleActive, !homeOperationsSuppressed,
              !didAttemptAutomaticConnection else { return }
        didAttemptAutomaticConnection = true
        guard await loadConfiguredClient() else { return }
        await connect()
    }

    func connect() async {
        guard isLifecycleActive, !homeOperationsSuppressed,
              connectionState != .connecting else { return }

        if transportMode == .home {
            await connectHome()
            return
        }

        connectionState = .connecting
        do {
            let metadata = try await client.connect()
            sessionMetadata = metadata
            sessionStartedAt = now()
            connectionState = .connected
            transientError = nil
        } catch {
            let message = error.localizedDescription
            sessionMetadata = nil
            sessionStartedAt = nil
            connectionState = .failed(message)
            transientError = message
        }
    }

    private func connectHome() async {
        guard !homeOperationsSuppressed else { return }
        guard let claim = homeClaim, let homeClient else {
            let failure = HomeBridgeFailure.home(
                code: .authorizationUnavailable,
                phase: .open
            )
            homeBridgeState = .unavailable(failure)
            connectionState = .failed(failure.safeReason)
            transientError = "Home pairing is unavailable for this Hermes Profile."
            return
        }

        if let recovery = homeRecovery, !recoveryMatches(recovery, claim: claim) {
            applyHomeConnectionFailure(
                .home(code: .conversationMismatch, phase: .reconnect),
                unavailable: true
            )
            return
        }

        homeBridgeState = .connecting
        homeRouteState = HomeRouteState(
            status: .attempting,
            identity: claim.approvedRoute.identity,
            failure: nil
        )
        connectionState = .connecting
        let outcome = await homeClient.open(claim: claim)
        guard !homeOperationsSuppressed else { return }

        switch outcome {
        case .ready(let binding, let capabilities):
            guard homeBinding(binding, matches: claim) else {
                let failure = HomeBridgeFailure.home(code: .conversationMismatch, phase: .open)
                applyHomeConnectionFailure(failure, unavailable: true)
                return
            }
            homeConversationBinding = binding
            if homeRecovery != nil {
                connectionState = .reconnecting(attempt: 1, of: reconnectPolicy.maxAttempts)
                await reconnectHome(
                    using: binding,
                    restoredTurn: homeTurnBinding,
                    client: homeClient
                )
                return
            }
            presentHomeReadyState(
                binding: binding,
                capabilities: capabilities,
                client: homeClient
            )
        case .unavailable(.reconnectRequired):
            guard let binding = reconnectBinding(for: claim) else {
                applyHomeConnectionFailure(
                    .home(code: .conversationMismatch, phase: .reconnect),
                    unavailable: true
                )
                return
            }
            homeConversationBinding = binding
            connectionState = .reconnecting(attempt: 1, of: reconnectPolicy.maxAttempts)
            await reconnectHome(
                using: binding,
                restoredTurn: homeTurnBinding,
                client: homeClient
            )
        case .unavailable(let failure):
            applyHomeConnectionFailure(failure, unavailable: true)
        case .disconnected(let failure):
            applyHomeConnectionFailure(failure, unavailable: false)
        }
    }

    private func reconnectHome(
        using binding: HomeConversationBinding,
        restoredTurn: HomeTurnBinding?,
        client: any HomeBridgeSessionClient
    ) async {
        switch await client.reconnect(binding: binding) {
        case .ready(let readyBinding, let unresolvedTurn):
            guard readyBinding == binding else {
                applyHomeConnectionFailure(
                    .home(code: .conversationMismatch, phase: .reconnect),
                    unavailable: true
                )
                return
            }
            if let unresolvedTurn {
                let turn = HomeTurnBinding(
                    conversationHandle: binding.conversationHandle,
                    turnID: unresolvedTurn.turnID,
                    correlationID: homeRecovery?.correlationID
                        ?? restoredTurn?.correlationID
                        ?? "unresolved"
                )
                homeTurnBinding = turn
                homeTurnDeliveryState = .uncertain(turn)
                if let recovery = homeRecovery {
                    homeRecovery = PersistedHomeRecovery(
                        profileID: recovery.profileID,
                        endpoint: recovery.endpoint,
                        route: recovery.route,
                        householdBinding: recovery.householdBinding,
                        conversationHandle: recovery.conversationHandle,
                        turnID: unresolvedTurn.turnID,
                        correlationID: recovery.correlationID,
                        submissionAttemptID: recovery.submissionAttemptID,
                        resumeCursor: unresolvedTurn.resumeCursor,
                        deliveryState: .uncertain,
                        updatedAt: now()
                    )
                }
            }
            presentHomeReadyState(
                binding: readyBinding,
                capabilities: readyBinding.capabilities,
                client: client
            )
            await persistConversation()
        case .unavailable(let failure):
            applyHomeConnectionFailure(failure, unavailable: true)
        case .disconnected(let failure):
            applyHomeConnectionFailure(failure, unavailable: false)
        }
    }

    private func presentHomeReadyState(
        binding: HomeConversationBinding,
        capabilities: HomeBridgeCapabilities,
        client: any HomeBridgeSessionClient
    ) {
        homeConversationBinding = binding
        homeBridgeState = .ready(binding)
        homeRouteState = HomeRouteState(
            status: .reachable,
            identity: binding.route,
            failure: nil
        )
        sessionMetadata = SessionMetadata(
            homeConversation: binding,
            capabilities: capabilities.commands.sorted()
                + (capabilities.heartbeat ? ["heartbeat"] : [])
                + (capabilities.interrupt ? ["interrupt"] : [])
        )
        sessionStartedAt = now()
        connectionState = .connected
        transientError = nil
        startHomeEventPump(client: client)
    }

    private func reconnectBinding(for claim: HomeConversationClaim) -> HomeConversationBinding? {
        if let recovery = homeRecovery {
            guard recoveryMatches(recovery, claim: claim) else { return nil }
            if let binding = homeConversationBinding, homeBinding(binding, matches: claim) {
                return binding
            }
            return HomeConversationBinding(
                profileID: recovery.profileID,
                conversationHandle: recovery.conversationHandle,
                endpoint: recovery.endpoint,
                route: recovery.route,
                householdBinding: recovery.householdBinding,
                capabilities: HomeBridgeCapabilities()
            )
        }
        if let binding = homeConversationBinding {
            return homeBinding(binding, matches: claim) ? binding : nil
        }
        guard claim.profileID == activeProfileID else { return nil }
        return HomeConversationBinding(
            profileID: claim.profileID,
            conversationHandle: claim.conversationHandle,
            endpoint: claim.approvedRoute.endpoint,
            route: claim.approvedRoute.identity,
            householdBinding: claim.approvedRoute.householdBinding,
            capabilities: HomeBridgeCapabilities()
        )
    }

    private func recoveryMatches(
        _ recovery: PersistedHomeRecovery,
        claim: HomeConversationClaim
    ) -> Bool {
        recovery.profileID == claim.profileID
            && recovery.conversationHandle == claim.conversationHandle
            && recovery.endpoint == claim.approvedRoute.endpoint
            && recovery.route == claim.approvedRoute.identity
            && recovery.householdBinding == claim.approvedRoute.householdBinding
    }

    private func homeBinding(
        _ binding: HomeConversationBinding,
        matches claim: HomeConversationClaim
    ) -> Bool {
        binding.profileID == activeProfileID
            && binding.profileID == claim.profileID
            && binding.conversationHandle == claim.conversationHandle
            && binding.endpoint == claim.approvedRoute.endpoint
            && binding.route == claim.approvedRoute.identity
            && binding.householdBinding == claim.approvedRoute.householdBinding
    }

    private func applyHomeConnectionFailure(
        _ failure: HomeBridgeFailure,
        unavailable: Bool
    ) {
        homeBridgeState = unavailable ? .unavailable(failure) : .disconnected(failure)
        if case .route(let routeFailure) = failure {
            homeRouteState = HomeRouteState(
                status: .failed,
                identity: homeClaim?.approvedRoute.identity,
                failure: routeFailure
            )
        }
        connectionState = unavailable ? .failed(failure.safeReason) : .disconnected
        sessionMetadata = nil
        sessionStartedAt = nil
        activityText = nil
        transientError = failure.safeReason
    }

    private func startHomeEventPump(client: any HomeBridgeSessionClient) {
        homeEventTask?.cancel()
        homeEventTask = Task { [weak self] in
            let stream = await client.events()
            do {
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    await self?.handleHomeEvent(event)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.handleUnexpectedHomeTransportLoss()
            }
        }
    }

    private func handleHomeEvent(_ event: HomeBridgeEvent) async {
        guard isLifecycleActive, !homeOperationsSuppressed else { return }
        guard let binding = homeConversationBinding else { return }

        switch event {
        case .standard(let standard):
            guard standard.scope.conversationHandle == binding.conversationHandle else { return }
            guard isCurrentHomeEvent(standard.scope) else { return }
            let normalized = homeNormalizer.normalizeHome(standard)
            for event in normalized {
                apply(event)
                if let homeEventHandler { await homeEventHandler(event) }
                if case .turnComplete = event {
                    finishHomeControlTurn(success: true)
                } else if case .turnInterrupted = event {
                    finishHomeControlTurn(success: false)
                }
            }
        case .audioStart(let scope, let format):
            guard isCurrentHomeEvent(scope),
                  !homeAudioTerminal,
                  !homeAudioTerminalProcessing else { return }
            guard format.isValidSignedPCM else {
                await markHomeAudioFailure(generation: nextTurnGeneration)
                return
            }
            homeAudioRequested = true
            homeAudioTerminal = false
            homeAudioStartTimeoutTask?.cancel()
            homeAudioStartTimeoutTask = nil
            homeAudioState = .streaming(format: format, generation: nextTurnGeneration)
            scheduleHomeAudioDeadline(for: homeTurnBinding)
            for event in homeNormalizer.normalizeHomeAudio(event) {
                if let homeEventHandler { await homeEventHandler(event) }
            }
        case .binaryPCM(let scope, let data):
            guard isCurrentHomeEvent(scope),
                  !homeAudioTerminal,
                  !homeAudioTerminalProcessing,
                  !data.isEmpty else { return }
            for event in homeNormalizer.normalizeHomeAudio(event) {
                if let homeEventHandler { await homeEventHandler(event) }
            }
        case .audioTerminal(let scope, let terminal):
            guard isCurrentHomeEvent(scope),
                  !homeAudioTerminal,
                  !homeAudioTerminalProcessing else { return }
            homeAudioTerminalProcessing = true
            switch terminal {
            case .end:
                homeAudioState = .ended(generation: nextTurnGeneration)
            case .fallback:
                homeAudioState = .fallback(generation: nextTurnGeneration)
            case .unavailable:
                homeAudioState = .unavailable(generation: nextTurnGeneration)
            case .invalid:
                homeAudioState = .invalid(generation: nextTurnGeneration)
            }
            homeAudioTimeoutTask?.cancel()
            homeAudioTimeoutTask = nil
            homeAudioStartTimeoutTask?.cancel()
            homeAudioStartTimeoutTask = nil
            for event in homeNormalizer.normalizeHomeAudio(event) {
                if let homeEventHandler { await homeEventHandler(event) }
            }
            homeAudioTerminalProcessing = false
            homeAudioTerminal = true
            resumeHomeAudioTerminalWaiter()
        case .structuredPrompt(let prompt):
            guard prompt.conversationHandle == binding.conversationHandle,
                  isCurrentHomeEvent(HomeEventScope(
                    conversationHandle: prompt.conversationHandle,
                    turnID: prompt.turnID,
                    correlationID: prompt.correlationID
                  )) else { return }
            pendingHomePrompt = HomePendingStructuredPrompt(
                prompt: prompt,
                receivedAt: now(),
                expiresAt: prompt.expiresAt
            )
        case .command(let command):
            guard command.conversationHandle == binding.conversationHandle else { return }
            homeCommandEvents.append(command)
            if homeCommandEvents.count > 20 { homeCommandEvents.removeFirst() }
        case .activity(let scope, let activity):
            if let scope, !isCurrentHomeEvent(scope) { return }
            activityText = activity == .idle || activity == .stopped ? nil : activity.rawValue
        }
    }

    private func isCurrentHomeEvent(_ scope: HomeEventScope) -> Bool {
        guard scope.conversationHandle == homeConversationBinding?.conversationHandle else { return false }
        guard let active = homeTurnBinding else { return scope.turnID == nil }
        guard let turnID = scope.turnID, turnID == active.turnID else { return false }
        // Standard's correlation ID belongs to the individual event or prompt;
        // the conversation handle and turn ID identify the active response.
        return true
    }

    private func finishHomeControlTurn(success: Bool) {
        guard let turn = homeTurnBinding else { return }
        homeControlTerminal = true
        if !success {
            homeAudioTerminal = true
            resumeHomeAudioTerminalWaiter()
        }
        homeControlTimeoutTask?.cancel()
        homeControlTimeoutTask = nil
        homeTurnDeliveryState = success ? .completed(turn) : .interrupted(turn)
        homeTurnResult = success
        resumeHomeTurnWaiters(returning: success)
    }

    private func scheduleHomeControlDeadline(for turn: HomeTurnBinding) {
        homeControlTimeoutTask?.cancel()
        let deadline = homeClock.now().advanced(
            by: homeTurnAudioDeadlines.controlTerminal
        )
        homeControlTimeoutTask = Task { [weak self] in
            do {
                try await self?.homeClock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self,
                  self.homeTurnBinding == turn,
                  !self.homeControlTerminal else { return }
            self.homeJoinTimeout = .controlTerminalMissing
            let conversation = self.homeConversationBinding
            let text = self.activeTurnText
                ?? self.unconfirmedTurnText
                ?? self.messages.last(where: { $0.role == .user })?.text
                ?? ""
            if let conversation {
                await self.markHomeSubmissionUncertain(
                    failure: .home(code: .transportTimeout, phase: .reconnect),
                    text: text,
                    conversation: conversation,
                    attemptID: self.homeRecovery?.submissionAttemptID ?? UUID(),
                    turn: turn
                )
            }
            self.resumeHomeTurnWaiters(returning: false)
        }
    }

    private func scheduleHomeAudioDeadline(for turn: HomeTurnBinding?) {
        guard let turn else { return }
        homeAudioTimeoutTask?.cancel()
        let deadline = homeClock.now().advanced(
            by: homeTurnAudioDeadlines.audioTerminal
        )
        homeAudioTimeoutTask = Task { [weak self] in
            do {
                try await self?.homeClock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self,
                  self.homeTurnBinding == turn else { return }
            guard case .streaming = self.homeAudioState,
                  !self.homeAudioTerminal,
                  !self.homeAudioTerminalProcessing else { return }
            self.homeJoinTimeout = .audioTerminalMissing
            await self.markHomeAudioUnavailable(generation: self.nextTurnGeneration)
        }
    }

    private func scheduleHomeAudioStartDeadline(for turn: HomeTurnBinding) {
        homeAudioStartTimeoutTask?.cancel()
        let deadline = homeClock.now().advanced(
            by: homeTurnAudioDeadlines.audioStart
        )
        homeAudioStartTimeoutTask = Task { [weak self] in
            do {
                try await self?.homeClock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self,
                  self.homeTurnBinding == turn,
                  !self.homeAudioRequested,
                  !self.homeAudioTerminal,
                  !self.homeAudioTerminalProcessing else { return }
            self.homeJoinTimeout = .audioStartMissing
            await self.markHomeAudioUnavailable(generation: self.nextTurnGeneration)
        }
    }

    private func markHomeAudioFailure(generation: UInt64) async {
        await finishHomeAudio(
            state: .invalid(generation: generation),
            reason: "invalid Home PCM audio"
        )
    }

    private func markHomeAudioUnavailable(generation: UInt64) async {
        await finishHomeAudio(
            state: .unavailable(generation: generation),
            reason: "unavailable"
        )
    }

    private func finishHomeAudio(state: HomeAudioState, reason: String) async {
        guard !homeAudioTerminal, !homeAudioTerminalProcessing else { return }
        homeAudioState = state
        homeAudioTerminalProcessing = true
        if let homeEventHandler {
            await homeEventHandler(.audioAbort(
                turnID: homeTurnBinding?.turnID ?? "home",
                reason: reason
            ))
        }
        homeAudioTerminalProcessing = false
        homeAudioTerminal = true
        resumeHomeAudioTerminalWaiter()
    }

    @discardableResult
    func sendDraft(
        eventHandler: (@MainActor @Sendable (HermesEvent) async -> Void)? = nil
    ) async -> Bool {
        let originalDraft = draft
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        // Once a connected turn is accepted, the composer represents a new
        // draft. Clear it before waiting for the streamed response so the
        // field does not look stuck while Hermes is working. If the turn
        // fails, restore the original text unless the user has already
        // started editing a new draft.
        let shouldClearDraft = verifiedTurnBinding != nil && !isSending
        if shouldClearDraft {
            draft = ""
        }

        let completed = await sendTurn(text: text, eventHandler: eventHandler)
        if !completed, shouldClearDraft, draft.isEmpty {
            draft = originalDraft
            await persistConversation()
        }
        return completed
    }

    @discardableResult
    func sendTurn(
        text: String,
        expectedBinding: HermesTurnBinding? = nil,
        eventHandler: (@MainActor @Sendable (HermesEvent) async -> Void)? = nil
    ) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if transportMode == .home {
            return await sendHomeTurn(
                text: text,
                expectedBinding: expectedBinding,
                eventHandler: eventHandler
            )
        }
        guard let currentBinding = verifiedTurnBinding else {
            if draft.isEmpty {
                draft = text
            }
            transientError = "Connect to the Hermes relay before sending."
            await persistConversation()
            return false
        }
        guard expectedBinding == nil || expectedBinding == currentBinding else {
            transientError = "The selected Hermes Profile changed. Start a new turn."
            return false
        }
        guard !isSending else {
            transientError = "A Hermes turn is already in progress."
            return false
        }

        isSending = true
        activeAssistantID = nil
        activityText = nil
        transientError = nil
        turnCompleted = false
        interruptedTurnGeneration = nil
        interruptionConfirmedTurnGeneration = nil
        unconfirmedTurnText = nil
        nextTurnGeneration &+= 1
        let turnGeneration = nextTurnGeneration
        activeTurnGeneration = turnGeneration
        activeTurnText = text
        messages.append(TranscriptMessage(role: .user, text: text))
        var didComplete = false

        do {
            let events = await client.sendTurn(text: text)
            for try await event in events {
                guard activeTurnGeneration == turnGeneration else { break }
                apply(event)
                if let eventHandler {
                    await eventHandler(event)
                }
            }
        } catch {
            if interruptedTurnGeneration != turnGeneration {
                activeTurnGeneration = nil
                interruptedTurnGeneration = nil
                let message = error.localizedDescription
                if case RelaySessionError.disconnected = error {
                    connectionState = .disconnected
                    sessionMetadata = nil
                    sessionStartedAt = nil
                } else if case RelaySessionError.connectionTimedOut = error {
                    connectionState = .disconnected
                    sessionMetadata = nil
                    sessionStartedAt = nil
                } else if case RelaySessionError.notConnected = error {
                    connectionState = .disconnected
                    sessionMetadata = nil
                    sessionStartedAt = nil
                }
                transientError = message
                messages.append(TranscriptMessage(role: .error, text: message))
                unconfirmedTurnText = text
                if draft.isEmpty {
                    draft = text
                }
            }
        }
        let wasInterrupted = interruptedTurnGeneration == turnGeneration
        interruptedTurnGeneration = nil
        interruptionConfirmedTurnGeneration = nil
        activeTurnGeneration = nil
        activeTurnText = nil
        if wasInterrupted {
            isSending = false
            activeAssistantID = nil
            await persistConversation()
            return false
        }
        didComplete = turnCompleted
        activityText = nil
        if !didComplete {
            unconfirmedTurnText = text
            activeAssistantID = nil
        }
        isSending = false
        await persistConversation()
        return didComplete
    }

    @discardableResult
    private func sendHomeTurn(
        text: String,
        expectedBinding: HermesTurnBinding?,
        eventHandler: (@MainActor @Sendable (HermesEvent) async -> Void)?
    ) async -> Bool {
        guard let currentBinding = verifiedTurnBinding,
              let conversation = currentBinding.homeConversation,
              let homeClient else {
            if draft.isEmpty { draft = text }
            transientError = turnUnavailableMessage
            await persistConversation()
            return false
        }
        guard expectedBinding == nil || isCurrentTurnBinding(expectedBinding!) else {
            transientError = "The selected Hermes Profile changed. Start a new turn."
            return false
        }
        let replacingExistingRecovery = homeRecovery != nil
            && unconfirmedTurnText == text
        let previousHomeRecovery = homeRecovery
        let previousDeliveryState = homeTurnDeliveryState
        let previousUnconfirmedText = unconfirmedTurnText
        let previousHomeTurnBinding = homeTurnBinding
        let knownFailureCanBeRetried: Bool
        if case .failedKnown = homeTurnDeliveryState {
            knownFailureCanBeRetried = true
        } else {
            knownFailureCanBeRetried = false
        }
        guard !isSending,
              (homeRecovery == nil || replacingExistingRecovery),
              homeTurnDeliveryState == .idle || knownFailureCanBeRetried || replacingExistingRecovery else {
            transientError = "A Hermes turn is already in progress or awaiting resolution."
            return false
        }

        isSending = true
        activeTurnText = text
        activeAssistantID = nil
        activityText = nil
        transientError = nil
        turnCompleted = false
        homeControlTerminal = false
        homeAudioRequested = false
        homeAudioState = .notRequested
        homeAudioTerminal = eventHandler == nil
        homeAudioTerminalProcessing = false
        homeNormalizer = HermesEventNormalizer()
        homeEventHandler = eventHandler
        homeTurnResult = nil
        nextTurnGeneration &+= 1
        activeTurnGeneration = nextTurnGeneration
        let attemptID = UUID()
        homeTurnDeliveryState = .awaitingAcceptance(attemptID: attemptID)
        // This marker is the local copy that makes an awaiting-acceptance
        // record actionable after a crash. The recovery schema deliberately
        // contains no prompt text; the text lives in the existing local
        // conversation field instead.
        unconfirmedTurnText = text
        homeRecovery = makeHomeRecovery(
            conversation: conversation,
            turn: nil,
            attemptID: attemptID,
            deliveryState: .awaitingAcceptance,
            resumeCursor: nil
        )
        guard await persistConversation() else {
            homeRecovery = previousHomeRecovery
            homeTurnDeliveryState = previousDeliveryState
            unconfirmedTurnText = previousUnconfirmedText
            homeEventHandler = nil
            activeTurnText = nil
            isSending = false
            return false
        }

        let outcome = await homeClient.submitPrompt(text, binding: conversation)
        guard isLifecycleActive, !homeOperationsSuppressed else {
            await markHomeSubmissionUncertain(
                failure: .home(code: .transportUnavailable, phase: .submission),
                text: text,
                conversation: conversation,
                attemptID: attemptID
            )
            return false
        }

        switch outcome {
        case .accepted(let turn):
            let recovery = makeHomeRecovery(
                conversation: conversation,
                turn: turn,
                attemptID: attemptID,
                deliveryState: .accepted,
                resumeCursor: nil
            )
            homeTurnBinding = turn
            homeTurnDeliveryState = .accepted(turn)
            homeRecovery = recovery
            unconfirmedTurnText = text
            // The accepted opaque binding reaches disk before the visible
            // user message or any normalized response event.
            guard await persistConversation() else {
                await markHomeSubmissionUncertain(
                    failure: .home(code: .transportUnavailable, phase: .lifecycle),
                    text: text,
                    conversation: conversation,
                    attemptID: attemptID,
                    turn: turn
                )
                return false
            }
            messages.append(TranscriptMessage(role: .user, text: text))
            await persistConversation()
            scheduleHomeControlDeadline(for: turn)
            scheduleHomeAudioStartDeadline(for: turn)
            let completed = await waitForHomeTurnCompletion(turn: turn)
            if completed, eventHandler != nil {
                await waitForHomeAudioTerminal(turn: turn)
            }
            homeEventHandler = nil
            activeTurnText = nil
            if !completed {
                if case .interrupted = homeTurnDeliveryState {
                    await completeHomeTurnAfterAudio()
                }
                activityText = nil
                isSending = false
                await persistConversation()
                return false
            }
            // Voice playback owns the final drain. Text-only callers can
            // explicitly settle through completeHomeTurnAfterAudio().
            if eventHandler == nil {
                await completeHomeTurnAfterAudio()
            }
            return true
        case .rejected(let failure):
            homeRecovery = previousHomeRecovery
            homeTurnBinding = previousHomeTurnBinding
            homeTurnDeliveryState = previousHomeRecovery == nil
                ? .failedKnown(failure)
                : previousDeliveryState
            homeEventHandler = nil
            activeTurnText = nil
            isSending = false
            unconfirmedTurnText = previousUnconfirmedText
            transientError = failure.safeReason
            await persistConversation()
            return false
        case .uncertain(let failure):
            await markHomeSubmissionUncertain(
                failure: failure,
                text: text,
                conversation: conversation,
                attemptID: attemptID
            )
            return false
        }
    }

    private func waitForHomeTurnCompletion(turn: HomeTurnBinding) async -> Bool {
        guard homeTurnBinding == turn else { return false }
        if let homeTurnResult { return homeTurnResult }
        return await withCheckedContinuation { continuation in
            homeTurnWaiters.append(continuation)
        }
    }

    private func resumeHomeTurnWaiters(returning result: Bool) {
        let waiters = homeTurnWaiters
        homeTurnWaiters.removeAll()
        waiters.forEach { $0.resume(returning: result) }
    }

    private func waitForHomeAudioTerminal(turn: HomeTurnBinding) async {
        guard homeTurnBinding == turn, !homeAudioTerminal else { return }
        await withCheckedContinuation { continuation in
            homeAudioTerminalWaiter = continuation
            if homeAudioTerminal {
                homeAudioTerminalWaiter = nil
                continuation.resume()
            }
        }
    }

    private func resumeHomeAudioTerminalWaiter() {
        guard !homeAudioTerminalProcessing,
              let waiter = homeAudioTerminalWaiter else { return }
        homeAudioTerminalWaiter = nil
        waiter.resume()
    }

    private func makeHomeRecovery(
        conversation: HomeConversationBinding,
        turn: HomeTurnBinding?,
        attemptID: UUID?,
        deliveryState: PersistedHomeDeliveryState,
        resumeCursor: String?
    ) -> PersistedHomeRecovery {
        PersistedHomeRecovery(
            profileID: conversation.profileID,
            endpoint: conversation.endpoint,
            route: conversation.route,
            householdBinding: conversation.householdBinding,
            conversationHandle: conversation.conversationHandle,
            turnID: turn?.turnID,
            correlationID: turn?.correlationID,
            submissionAttemptID: attemptID,
            resumeCursor: resumeCursor,
            deliveryState: deliveryState,
            updatedAt: now()
        )
    }

    private func markHomeSubmissionUncertain(
        failure: HomeBridgeFailure,
        text: String,
        conversation: HomeConversationBinding,
        attemptID: UUID,
        turn: HomeTurnBinding? = nil
    ) async {
        homeRecovery = makeHomeRecovery(
            conversation: conversation,
            turn: turn,
            attemptID: attemptID,
            deliveryState: .uncertain,
            resumeCursor: nil
        )
        homeTurnBinding = turn
        homeTurnDeliveryState = .uncertain(turn)
        unconfirmedTurnText = text
        transientError = failure.safeReason
        activityText = nil
        isSending = false
        activeTurnText = nil
        homeEventHandler = nil
        homeEventTask?.cancel()
        homeEventTask = nil
        homeControlTimeoutTask?.cancel()
        homeControlTimeoutTask = nil
        homeAudioTimeoutTask?.cancel()
        homeAudioTimeoutTask = nil
        homeAudioTerminalWaiter?.resume()
        homeAudioTerminalWaiter = nil
        homeAudioTerminal = true
        homeAudioTerminalProcessing = false
        homeBridgeState = .disconnected(failure)
        connectionState = .disconnected
        sessionMetadata = nil
        sessionStartedAt = nil
        let oldClient = homeClient
        homeClient = nil
        await oldClient?.close()
        homeClient = homeClientFactory?.make(
            profileID: conversation.profileID,
            mode: .home
        )
        await persistConversation()
    }

    /// Playback owns the last part of a Home turn. The control terminal is
    /// known before native audio has necessarily drained, so this is the only
    /// method allowed to clear the persisted accepted binding.
    func completeHomeTurnAfterAudio() async {
        guard isHomeMode, homeTurnBinding != nil else { return }
        guard homeControlTerminal, homeAudioTerminal else { return }
        homeRecovery = nil
        homeControlTimeoutTask?.cancel()
        homeControlTimeoutTask = nil
        homeAudioTimeoutTask?.cancel()
        homeAudioTimeoutTask = nil
        homeAudioStartTimeoutTask?.cancel()
        homeAudioStartTimeoutTask = nil
        homeJoinTimeout = nil
        activityText = nil
        homeTurnBinding = nil
        homeTurnDeliveryState = .idle
        unconfirmedTurnText = nil
        homeAudioState = .notRequested
        homeAudioTerminal = true
        homeAudioTerminalProcessing = false
        homeAudioTerminalWaiter?.resume()
        homeAudioTerminalWaiter = nil
        activeTurnGeneration = nil
        activeTurnText = nil
        isSending = false
        homeEventHandler = nil
        await persistConversation()
    }

    func respondToHomePrompt(
        _ response: HomePromptResponse
    ) async -> HomeStructuredResponseOutcome {
        guard let pending = pendingHomePrompt, let homeClient else {
            return .rejected(.home(code: .requestRejected, phase: .structuredResponse))
        }
        let outcome = await homeClient.respond(to: pending.prompt, with: response)
        if case .accepted = outcome { pendingHomePrompt = nil }
        return outcome
    }

    func dispatchHomeCommand(
        name: String,
        argument: String? = nil
    ) async -> HomeCommandOutcome {
        guard let binding = homeConversationBinding, let homeClient else {
            return .rejected(.home(code: .transportUnavailable, phase: .command))
        }
        let command = HomeCommandRequest(binding: binding, name: name, argument: argument)
        return await homeClient.dispatch(command)
    }

    func pingHome() async -> HomePingOutcome {
        guard let binding = homeConversationBinding, let homeClient else {
            return .unavailable(.home(code: .transportUnavailable, phase: .ping))
        }
        return await homeClient.ping(binding: binding)
    }

    func currentHomeClientForLifecycle() -> (any HomeBridgeSessionClient)? {
        homeClient
    }

    func takeHomeClientForLifecycle() -> (any HomeBridgeSessionClient)? {
        homeEventTask?.cancel()
        homeEventTask = nil
        homeControlTimeoutTask?.cancel()
        homeControlTimeoutTask = nil
        homeAudioStartTimeoutTask?.cancel()
        homeAudioStartTimeoutTask = nil
        homeAudioTimeoutTask?.cancel()
        homeAudioTimeoutTask = nil
        homeAudioTerminalWaiter?.resume()
        homeAudioTerminalWaiter = nil
        homeAudioTerminal = true
        homeAudioTerminalProcessing = false
        let activeClient = homeClient
        homeClient = nil
        homeConversationBinding = nil
        homeTurnBinding = nil
        return activeClient
    }

    /// Persist the exact local state that crosses a lifecycle boundary. This
    /// method deliberately does not close a socket; the lifecycle owner does
    /// that only after the snapshot and native teardown succeed.
    func lifecycleWillDeactivate() async -> Bool {
        guard isLifecycleActive else { return true }

        if isSending {
            if isHomeMode, let recovery = homeRecovery {
                let recoveryText = unconfirmedTurnText
                    ?? messages.last(where: { $0.role == .user })?.text
                    ?? ""
                homeRecovery = PersistedHomeRecovery(
                    profileID: recovery.profileID,
                    endpoint: recovery.endpoint,
                    route: recovery.route,
                    householdBinding: recovery.householdBinding,
                    conversationHandle: recovery.conversationHandle,
                    turnID: recovery.turnID,
                    correlationID: recovery.correlationID,
                    submissionAttemptID: recovery.submissionAttemptID,
                    resumeCursor: recovery.resumeCursor,
                    deliveryState: .uncertain,
                    updatedAt: now()
                )
                homeTurnDeliveryState = .uncertain(homeTurnBinding)
                unconfirmedTurnText = recoveryText
            } else if let activeTurnText {
                unconfirmedTurnText = activeTurnText
            }
        }

        guard await persistConversation() else {
            transientError = "The local conversation could not be saved. Try again before leaving."
            return false
        }

        isLifecycleActive = false
        homeOperationsSuppressed = true
        reconnectTask?.cancel()
        reconnectTask = nil
        homeEventTask?.cancel()
        homeEventTask = nil
        homeControlTimeoutTask?.cancel()
        homeControlTimeoutTask = nil
        homeAudioStartTimeoutTask?.cancel()
        homeAudioStartTimeoutTask = nil
        homeAudioTimeoutTask?.cancel()
        homeAudioTimeoutTask = nil
        resumeHomeTurnWaiters(returning: false)
        homeAudioTerminalWaiter?.resume()
        homeAudioTerminalWaiter = nil
        homeAudioTerminal = true
        homeAudioTerminalProcessing = false
        homeTurnResult = false
        return true
    }

    func setLifecycleActive(_ active: Bool) {
        isLifecycleActive = active
        homeOperationsSuppressed = !active
        if active {
            homeTurnResult = nil
        }
    }

    /// Clears ownership before awaiting the actor's close. Calling this twice
    /// therefore cannot close the same Home client twice.
    func closeHomeClient() async {
        let activeClient = takeHomeClientForLifecycle()
        await activeClient?.close()
    }

    @discardableResult
    func interruptActiveTurn() async -> Bool {
        guard isSending else { return false }

        if transportMode == .home {
            guard let binding = homeConversationBinding,
                  let turn = homeTurnBinding,
                  let homeClient else { return false }
            let outcome = await homeClient.interrupt(binding: binding, turnID: turn.turnID)
            switch outcome {
            case .acknowledged:
                // The Home acknowledgement is not the user-visible terminal;
                // wait for the matching turn_interrupted event.
                homeTurnResult = nil
                let confirmed = await waitForHomeTurnCompletion(turn: turn)
                if confirmed { return false }
                await completeHomeTurnAfterAudio()
                isSending = false
                activeTurnGeneration = nil
                activeTurnText = nil
                return true
            case .rejected(let failure), .unavailable(let failure):
                transientError = failure.safeReason
                return false
            case .uncertain(let failure):
                await markHomeSubmissionUncertain(
                    failure: failure,
                    text: unconfirmedTurnText
                        ?? activeTurnText
                        ?? messages.last(where: { $0.role == .user })?.text
                        ?? "",
                    conversation: binding,
                    attemptID: homeRecovery?.submissionAttemptID ?? UUID(),
                    turn: turn
                )
                activeTurnGeneration = nil
                return false
            }
        }

        guard let turnGeneration = activeTurnGeneration else { return false }

        interruptedTurnGeneration = turnGeneration
        if await client.interruptActiveTurn() {
            return true
        }

        // Older endpoints have no server-confirmed interruption. Preserve the
        // existing close-and-reconnect fallback, and let sendTurn mark the
        // submitted text unconfirmed rather than pretending Hermes stopped.
        interruptedTurnGeneration = nil
        interruptionConfirmedTurnGeneration = nil
        activeTurnGeneration = nil
        activeTurnText = nil
        isExpectedDisconnect = true
        await client.disconnect()
        isExpectedDisconnect = false
        connectionState = .disconnected
        sessionMetadata = nil
        sessionStartedAt = nil
        activityText = nil
        await connect()
        return connectionState.isConnected
    }

    /// Selecting a different profile is one action: drop the current relay and
    /// connect the chosen one. A failure surfaces honestly rather than falling
    /// back to the previous profile, which would connect the user to a relay
    /// they did not choose.
    func clearSelectedProfile() async {
        await resetForProfileChange(clearPersistence: true)
    }

    func switchToSelectedProfile() async {
        await resetForProfileChange(clearPersistence: false)

        guard await loadConfiguredClient() else { return }
        await loadPersistedConversation()
        await connect()
    }

    private func resetForProfileChange(clearPersistence: Bool) async {
        // A deliberate teardown, not an outage — without this the reconnect
        // ladder from IOS-25 would race the profile mutation.
        reconnectTask?.cancel()
        reconnectTask = nil
        isExpectedDisconnect = true
        await client.disconnect()
        isExpectedDisconnect = false
        await closeHomeClient()

        connectionState = .disconnected
        sessionMetadata = nil
        sessionStartedAt = nil
        activityText = nil

        // Clear before loading. The previous account's transcript must never
        // be on screen while the new profile's conversation is read. A
        // deleted profile also drops its persistence handle so a late turn
        // completion cannot recreate the removed conversation file.
        messages = []
        draft = ""
        unconfirmedTurnText = nil
        activeAssistantID = nil
        activeProfileID = nil
        activeProfileDisplayName = nil
        transientError = nil
        isSending = false
        activeTurnGeneration = nil
        activeTurnText = nil
        interruptedTurnGeneration = nil
        interruptionConfirmedTurnGeneration = nil
        turnCompleted = false
        homeRecovery = nil
        homeControlTimeoutTask?.cancel()
        homeControlTimeoutTask = nil
        homeAudioTimeoutTask?.cancel()
        homeAudioTimeoutTask = nil
        homeJoinTimeout = nil
        homeConversationBinding = nil
        homeTurnBinding = nil
        homeTurnDeliveryState = .idle
        homeAudioState = .notRequested
        homeBridgeState = .unconfigured
        homeOperationsSuppressed = false
        if clearPersistence {
            persistence = nil
        }
    }

    func clearTransientError() {
        transientError = nil
    }

    /// The relay can confirm a turn before the coordinator finishes draining
    /// already-scheduled audio. Keep the assistant identity observable until
    /// that playback lifecycle reaches its own terminal state.
    func settleActiveAssistantPresentation() {
        activeAssistantID = nil
    }

    var isReconnecting: Bool {
        reconnectTask != nil
    }

    /// Called when the transport reports a loss the user did not ask for.
    func handleUnexpectedTransportLoss() {
        if transportMode == .home {
            handleUnexpectedHomeTransportLoss()
            return
        }
        sessionMetadata = nil
        sessionStartedAt = nil
        guard !isExpectedDisconnect else {
            connectionState = .disconnected
            return
        }
        guard reconnectTask == nil else { return }

        connectionState = .disconnected
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    /// Test seam: await the in-flight recovery without exposing the task.
    func waitForReconnectToFinish() async {
        await reconnectTask?.value
    }

    private func handleUnexpectedHomeTransportLoss() {
        guard isLifecycleActive, !homeOperationsSuppressed else { return }
        if let recovery = homeRecovery,
           recovery.deliveryState != .uncertain {
            homeRecovery = PersistedHomeRecovery(
                profileID: recovery.profileID,
                endpoint: recovery.endpoint,
                route: recovery.route,
                householdBinding: recovery.householdBinding,
                conversationHandle: recovery.conversationHandle,
                turnID: recovery.turnID,
                correlationID: recovery.correlationID,
                submissionAttemptID: recovery.submissionAttemptID,
                resumeCursor: recovery.resumeCursor,
                deliveryState: .uncertain,
                updatedAt: now()
            )
            homeTurnDeliveryState = .uncertain(homeTurnBinding)
            if unconfirmedTurnText == nil {
                unconfirmedTurnText = messages.last(where: { $0.role == .user })?.text
            }
        }
        homeBridgeState = .disconnected(
            .home(code: .transportUnavailable, phase: .reconnect)
        )
        connectionState = .disconnected
        sessionMetadata = nil
        sessionStartedAt = nil
        if reconnectTask == nil {
            Task { await persistConversation() }
            reconnectTask = Task { [weak self] in
                await self?.runHomeReconnectLoop()
            }
        }
    }

    private func runHomeReconnectLoop() async {
        defer { reconnectTask = nil }
        guard let binding = homeConversationBinding,
              let homeClient else { return }
        let deadline = homeClock.now().advanced(by: homeOperationDeadlines.reconnectOverall)
        var attempt = 1
        while homeClock.now() < deadline,
              let delay = reconnectPolicy.delayNanoseconds(forAttempt: attempt) {
            connectionState = .reconnecting(
                attempt: attempt,
                of: reconnectPolicy.maxAttempts
            )
            do {
                try await homeClock.sleep(
                    until: homeClock.now().advanced(
                        by: .nanoseconds(Int64(delay))
                    )
                )
            } catch { return }
            if Task.isCancelled || !isLifecycleActive { return }

            switch await homeClient.reconnect(binding: binding) {
            case .ready(let readyBinding, let unresolvedTurn):
                guard readyBinding == binding else {
                    applyHomeConnectionFailure(
                        .home(code: .conversationMismatch, phase: .reconnect),
                        unavailable: true
                    )
                    return
                }
                if let unresolvedTurn {
                    homeTurnBinding = HomeTurnBinding(
                        conversationHandle: binding.conversationHandle,
                        turnID: unresolvedTurn.turnID,
                        correlationID: homeRecovery?.correlationID ?? "unresolved"
                    )
                    homeTurnDeliveryState = .uncertain(homeTurnBinding)
                    if let homeRecovery {
                        self.homeRecovery = PersistedHomeRecovery(
                            profileID: homeRecovery.profileID,
                            endpoint: homeRecovery.endpoint,
                            route: homeRecovery.route,
                            householdBinding: homeRecovery.householdBinding,
                            conversationHandle: homeRecovery.conversationHandle,
                            turnID: unresolvedTurn.turnID,
                            correlationID: homeRecovery.correlationID,
                            submissionAttemptID: homeRecovery.submissionAttemptID,
                            resumeCursor: unresolvedTurn.resumeCursor,
                            deliveryState: .uncertain,
                            updatedAt: now()
                        )
                    }
                }
                homeConversationBinding = readyBinding
                homeBridgeState = .ready(readyBinding)
                homeRouteState = HomeRouteState(
                    status: .reachable,
                    identity: readyBinding.route,
                    failure: nil
                )
                sessionMetadata = SessionMetadata(
                    homeConversation: readyBinding,
                    capabilities: readyBinding.capabilities.commands.sorted()
                )
                connectionState = .connected
                transientError = nil
                startHomeEventPump(client: homeClient)
                await persistConversation()
                return
            case .unavailable(let failure):
                applyHomeConnectionFailure(failure, unavailable: true)
                return
            case .disconnected(let failure):
                if attempt == reconnectPolicy.maxAttempts {
                    applyHomeConnectionFailure(failure, unavailable: false)
                    return
                }
            }
            attempt += 1
        }
        applyHomeConnectionFailure(
            .home(code: .transportTimeout, phase: .reconnect),
            unavailable: false
        )
    }

    private func runReconnectLoop() async {
        defer { reconnectTask = nil }

        var attempt = 1
        while let delay = reconnectPolicy.delayNanoseconds(forAttempt: attempt) {
            guard isLifecycleActive, !homeOperationsSuppressed else { return }
            connectionState = .reconnecting(attempt: attempt, of: reconnectPolicy.maxAttempts)
            await sleep(delay)
            if Task.isCancelled || !isLifecycleActive || homeOperationsSuppressed { return }

            do {
                let metadata = try await client.connect()
                sessionMetadata = metadata
                sessionStartedAt = now()
                connectionState = .connected
                transientError = nil
                return
            } catch is RelayUnavailableError {
                // Configuration or credentials are wrong; retrying cannot fix it.
                fail(with: RelayUnavailableError())
                return
            } catch {
                if attempt == reconnectPolicy.maxAttempts {
                    fail(with: error)
                    return
                }
            }
            attempt += 1
        }
    }

    private func fail(with error: Error) {
        let message = error.localizedDescription
        sessionMetadata = nil
        sessionStartedAt = nil
        connectionState = .failed(message)
        transientError = message
    }

    private func apply(_ event: HermesEvent) {
        // The transport can already have yielded frames when a terminal event
        // arrives. Once a turn is complete or its interruption is confirmed,
        // those frames are stale and must not create a second assistant
        // message or append an error. Events already buffered before the
        // confirmation remain valid and are allowed through.
        guard !turnCompleted, interruptionConfirmedTurnGeneration == nil else { return }
        switch event {
        case .messageStart:
            let message = TranscriptMessage(role: .assistant, text: "")
            activeAssistantID = message.id
            messages.append(message)
        case .textDelta(let text):
            if let index = activeAssistantIndex {
                messages[index].text += text
            } else {
                let message = TranscriptMessage(role: .assistant, text: text)
                activeAssistantID = message.id
                messages.append(message)
            }
        case .textReplace(let text):
            if let index = activeAssistantIndex {
                messages[index].text = text
            } else {
                let message = TranscriptMessage(role: .assistant, text: text)
                activeAssistantID = message.id
                messages.append(message)
            }
        case .thinkingDelta(let text):
            activityText = text
        case .status(let text, _):
            activityText = text
        case .audioStart, .audioChunk, .audioEnd,
             .audioFileStart, .audioFileChunk, .audioFileEnd, .audioAbort,
             .speechTiming, .unknown:
            break
        case .turnInterrupted:
            interruptedTurnGeneration = activeTurnGeneration
            interruptionConfirmedTurnGeneration = activeTurnGeneration
            activeAssistantID = nil
            activityText = nil
        case .messageComplete(_, _, let failureReason):
            if !failureReason.isEmpty {
                transientError = failureReason
            }
        case .turnComplete:
            turnCompleted = true
            activityText = nil
            unconfirmedTurnText = nil
        case .error(let text):
            transientError = text
            messages.append(TranscriptMessage(role: .error, text: text))
        }
    }

    private var activeAssistantIndex: Int? {
        guard let activeAssistantID else { return nil }
        return messages.firstIndex { $0.id == activeAssistantID }
    }

    @discardableResult
    private func persistConversation() async -> Bool {
        guard let persistence else { return true }
        do {
            try await persistence.save(
                PersistedConversation(
                    messages: messages,
                    draft: draft,
                    unconfirmedTurnText: unconfirmedTurnText,
                    homeRecovery: homeRecovery
                )
            )
            return true
        } catch {
            if transientError == nil {
                transientError = "The local conversation could not be saved."
            }
            return false
        }
    }
}
