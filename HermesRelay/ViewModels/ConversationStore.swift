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
    private var homeAudioLastReceivedAt: ContinuousClock.Instant?
    private var homeClient: (any HomeBridgeSessionClient)?
    private var homeClaim: HomeConversationClaim?
    private var homeConversationBinding: HomeConversationBinding?
    private var homeTurnBinding: HomeTurnBinding?
    private var homeRecovery: PersistedHomeRecovery?
    private var homeEventTask: Task<Void, Never>?
    private var homeTurnWaiters: [(turn: HomeTurnBinding, continuation: CheckedContinuation<Bool, Never>)] = []
    private var homeAudioTerminalWaiter: CheckedContinuation<Void, Never>?
    private var homeTurnResult: (turn: HomeTurnBinding?, completed: Bool)?
    private var homeEventHandler: (@MainActor @Sendable (HermesEvent) async -> Void)?
    private var homeNormalizer = HermesEventNormalizer()
    private var homeControlTerminal = false
    private var homeAudioTerminal = true
    private var homeAudioTerminalProcessing = false
    private var homeReconnectConfirmsNoUnresolvedTurn = false
    private var homeAudioRequested = false
    private var homeControlTimeoutTask: Task<Void, Never>?
    /// With keep-alives: restarted by every sign of life from the turn.
    private var homeControlIdleTask: Task<Void, Never>?
    private var homeTurnUsesKeepalive = false
    private var homeKeepaliveAwaitingInput = false
    private var homeAudioStartTimeoutTask: Task<Void, Never>?
    private var homeAudioTimeoutTask: Task<Void, Never>?
    private(set) var homeJoinTimeout: HomeTurnJoinTimeout?
    private var homeOperationsSuppressed = false
    private var activeTurnText: String?
    /// A paired personal client makes a fresh single-use claim on each
    /// connect. Its handle is kept in memory only.
    private var homeClaimsPerConnect = false
    /// The local divider to insert once the next paired claim is ready.
    private var pendingHomeDividerText: String?
    /// The session the next paired claim names. Connecting continues the
    /// Profile's latest session; the Sessions sheet can choose otherwise.
    private var nextHomeSessionChoice: HomeClientSessionChoice = .mostRecent
    /// The title of a session chosen from the list, for its divider.
    private var pendingHomeSessionTitle: String?
    /// The Hermes session of the current paired claim. Memory only: the
    /// reference is opaque and grant-scoped, and titles are user content.
    private(set) var homeSession: HomeCurrentSession?
    /// Set when Home can no longer resume the conversation that holds an
    /// uncertain turn; the user must choose to start a new one.
    private(set) var canStartNewHomeConversation = false

    /// A response received after its owner operation ended is retained only
    /// in memory until it can be closed or reused; it is never recreated.
    private var pendingHomeClaimsByProfile: [UUID: HomeConversationClaim] = [:]
    private var ambiguousClaimCreationRetryAfter: [UUID: ContinuousClock.Instant] = [:]
    private static let ambiguousClaimRetryDelay: Duration = .seconds(90)
    #if DEBUG
    private var debugHomeClaimsEnabled = false
    private static let debugHomeProfileID = UUID()
    #endif
    private var homeLifecycleGeneration: UInt64 = 0
    private var configurationLoadGeneration: UInt64 = 0
    private var homeConnectOperationInProgress = false
    private var homeConnectWaiters: [CheckedContinuation<Void, Never>] = []
    private var openHomeClaimsGeneration: UInt64 = 0
    private var homeClaimMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var homeClaimLifecycleMutationInProgress = false
    private(set) var openHomeClaimList: HomeClientActiveClaimList?
    private(set) var openHomeClaimTitles: [String: String] = [:]
    private(set) var openHomeClaimsError: String?
    private(set) var canManageOpenHomeClaims = false
    private(set) var shouldOfferManageOpenHomeClaims = false
    private(set) var isClosingOpenHomeClaims = false

    static let newHomeConversationDividerText = "New conversation"
    static let resumedLatestHomeSessionDividerText = "Continued the latest conversation"

    static func resumedHomeSessionDividerText(title: String?) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Resumed an earlier conversation"
        }
        return "Resumed: \(title)"
    }

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
    private(set) var canContinueWithoutResendingHomeTurn = false
    private(set) var homeAudioState: HomeAudioState = .notRequested
    private(set) var pendingHomePrompt: HomePendingStructuredPrompt?
    private(set) var homeCommandEvents: [HomeCommandEvent] = []
    private(set) var isLifecycleActive = true

    var isHomeMode: Bool { transportMode == .home }

    private var homeAudioHasSettled: Bool {
        homeAudioTerminal && !homeAudioTerminalProcessing
    }

    private func refreshHomeContinueWithoutResendingEligibility() {
        canContinueWithoutResendingHomeTurn = homeReconnectConfirmsNoUnresolvedTurn
            && homeRecovery != nil
            && homeAudioHasSettled
            && connectionState.isConnected
            && !homeOperationsSuppressed
            && !isSending
    }

    private var transportMode: AppleTransportMode = .legacy

    /// A turn may begin only from a connection that completed the Hermes
    /// handshake. `connectionState` alone is deliberately insufficient: the
    /// metadata is the proof that `hello_ack` was accepted.
    var verifiedTurnBinding: HermesTurnBinding? {
        guard connectionState.isConnected, !homeOperationsSuppressed else { return nil }
        if transportMode == .home {
            // A Home turn needs the live transport, not just a cached state.
            guard let homeConversationBinding, homeClient != nil else { return nil }
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
    // A Home open or reconnect that failed at the transport is retried on the
    // reconnect policy's ladder, reusing the held claim. A fresh connect,
    // Disconnect, lifecycle change, or profile change ends the ladder.
    private var homeConnectRetryTask: Task<Void, Never>?
    private var homeConnectRetryAttempt = 0
    private var homeConnectRetryDeadline: ContinuousClock.Instant?
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

    func configureDebugHomeClaims(enabled: Bool) {
        #if DEBUG
        debugHomeClaimsEnabled = enabled
        #endif
    }

    func loadPersistedConversation() async {
        guard let persistence else { return }

        do {
            let conversation = try await persistence.load()
            let restoredRecovery = restoredHomeRecovery(conversation.homeRecovery)
            messages = conversation.messages
            draft = conversation.draft
            unconfirmedTurnText = conversation.unconfirmedTurnText
            homeRecovery = restoredRecovery
            if let recovery = restoredRecovery {
                let recoveryText = conversation.unconfirmedTurnText
                    ?? messages.last(where: { $0.role == .user })?.text
                    ?? ""
                let recoveryBinding = HomeTurnBinding(
                    conversationHandle: recovery.conversationHandle,
                    turnID: recovery.turnID ?? "unconfirmed",
                    correlationID: recovery.turnID == nil
                        ? recovery.correlationID ?? "unconfirmed"
                        : recovery.correlationID
                )
                // Home may accept a turn without a correlation ID; the turn ID is enough to restore it.
                let persistedTurn: HomeTurnBinding? = if let turnID = recovery.turnID {
                    HomeTurnBinding(
                        conversationHandle: recovery.conversationHandle,
                        turnID: turnID,
                        correlationID: recovery.correlationID
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
                            homeRecovery: persistableHomeRecovery(homeRecovery)
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
        configurationLoadGeneration &+= 1
        let loadGeneration = configurationLoadGeneration

        do {
            guard let profile = try await configurationStore.loadProfile() else {
                guard loadGeneration == configurationLoadGeneration else { return false }
                #if DEBUG
                if debugHomeClaimsEnabled {
                    let profileID = Self.debugHomeProfileID
                    if activeProfileID != profileID {
                        homeLifecycleGeneration &+= 1
                        openHomeClaimsGeneration &+= 1
                        activeProfileID = profileID
                        activeProfileDisplayName = "Debug Home"
                        let claim = HomeDemoFixtures.claim(for: profileID)
                        homeClaim = claim
                        pendingHomeClaimsByProfile[profileID] = claim
                        homeSession = HomeCurrentSession(
                            sessionRef: "debug-session-current",
                            title: "Current debug conversation"
                        )
                        homeClient = nil
                        openHomeClaimList = nil
                        openHomeClaimTitles = [:]
                        openHomeClaimsError = nil
                    }
                    transportMode = .home
                    homeClaimsPerConnect = true
                    canManageOpenHomeClaims = true
                    shouldOfferManageOpenHomeClaims = false
                    homeOperationsSuppressed = !isLifecycleActive
                    transientError = nil
                    return true
                }
                #endif
                if activeProfileID != nil {
                    homeLifecycleGeneration &+= 1
                    openHomeClaimsGeneration &+= 1
                }
                activeProfileID = nil
                activeProfileDisplayName = nil
                canManageOpenHomeClaims = false
                openHomeClaimList = nil
                openHomeClaimTitles = [:]
                shouldOfferManageOpenHomeClaims = false
                transientError = "Configure a Hermes relay profile before connecting."
                return false
            }
            guard loadGeneration == configurationLoadGeneration else { return false }
            if activeProfileID != profile.id {
                homeLifecycleGeneration &+= 1
                cancelHomeConnectRetry()
                openHomeClaimsGeneration &+= 1
                canManageOpenHomeClaims = false
                openHomeClaimList = nil
                openHomeClaimTitles = [:]
                openHomeClaimsError = nil
                shouldOfferManageOpenHomeClaims = false
                if let previousClaim = homeClaim, previousClaim.profileID != profile.id {
                    pendingHomeClaimsByProfile[previousClaim.profileID] = previousClaim
                    homeClaim = nil
                }
                homeSession = nil
                nextHomeSessionChoice = .mostRecent
                pendingHomeSessionTitle = nil
            }
            let profileGeneration = homeLifecycleGeneration
            activeProfileID = profile.id
            activeProfileDisplayName = profile.displayName
            if let makePersistence {
                persistence = makePersistence(profile.id)
            }

            transportMode = try await configurationStore.transportMode(for: profile.id)
            guard loadGeneration == configurationLoadGeneration,
                  profileGeneration == homeLifecycleGeneration,
                  activeProfileID == profile.id else {
                return false
            }
            let claimsPerConnect = transportMode == .home
                ? await homeClaimProvider?.claimsPerConnect(for: profile.id) == true
                : false
            guard loadGeneration == configurationLoadGeneration,
                  profileGeneration == homeLifecycleGeneration,
                  activeProfileID == profile.id else {
                return false
            }
            let supportsClaimManagement = transportMode == .home
                ? await homeClaimProvider?.supportsClaimManagement(for: profile.id) == true
                : false
            guard loadGeneration == configurationLoadGeneration,
                  profileGeneration == homeLifecycleGeneration,
                  activeProfileID == profile.id else {
                return false
            }
            homeClaimsPerConnect = claimsPerConnect
            canManageOpenHomeClaims = supportsClaimManagement
            DiagnosticsJournal.shared.record(
                "profile loaded id=\(profile.id.uuidString.prefix(8)) mode=\(transportMode.rawValue) claims_per_connect=\(claimsPerConnect)"
            )
            if transportMode == .home {
                homeOperationsSuppressed = !isLifecycleActive
                homeConversationBinding = nil
                if homeRecovery == nil {
                    homeTurnBinding = nil
                    homeTurnDeliveryState = .idle
                }
                if claimsPerConnect {
                    // A single-use claim is created only when Connect runs.
                    homeClaim = homeClaim?.profileID == profile.id
                        ? homeClaim
                        : pendingHomeClaimsByProfile.removeValue(forKey: profile.id)
                    homeRouteState = HomeRouteState(
                        status: .unattempted,
                        identity: homeClaim?.approvedRoute.identity,
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
                guard loadGeneration == configurationLoadGeneration,
                      profileGeneration == homeLifecycleGeneration,
                      activeProfileID == profile.id else {
                    return false
                }
                homeClaim = claim
                canManageOpenHomeClaims = false
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
                guard loadGeneration == configurationLoadGeneration else { return false }
                transientError = "Add a Hermes relay token before connecting."
                return false
            }
            guard loadGeneration == configurationLoadGeneration,
                  profileGeneration == homeLifecycleGeneration,
                  activeProfileID == profile.id else {
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
            homeClaimsPerConnect = false
            canManageOpenHomeClaims = false
            homeConversationBinding = nil
            homeTurnBinding = nil
            homeBridgeState = .unconfigured
            transientError = nil
            return true
        } catch {
            guard loadGeneration == configurationLoadGeneration else { return false }
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
        cancelHomeConnectRetry()
        await performConnect()
    }

    private func performConnect() async {
        guard isLifecycleActive, !homeOperationsSuppressed else { return }
        while isClosingOpenHomeClaims || homeClaimLifecycleMutationInProgress {
            await withCheckedContinuation { homeClaimMutationWaiters.append($0) }
            guard isLifecycleActive, !homeOperationsSuppressed else { return }
        }
        if homeConnectOperationInProgress {
            await withCheckedContinuation { homeConnectWaiters.append($0) }
            return
        }

        homeConnectOperationInProgress = true
        defer { finishHomeConnectOperation() }
        let generation = homeLifecycleGeneration
        if transportMode == .home {
            await connectHome(operationGeneration: generation)
        } else {
            connectionState = .connecting
            do {
                let metadata = try await client.connect()
                guard generation == homeLifecycleGeneration,
                      isLifecycleActive, !homeOperationsSuppressed else { return }
                sessionMetadata = metadata
                sessionStartedAt = now()
                connectionState = .connected
                transientError = nil
            } catch {
                guard generation == homeLifecycleGeneration,
                      isLifecycleActive, !homeOperationsSuppressed else { return }
                let message = error.localizedDescription
                sessionMetadata = nil
                sessionStartedAt = nil
                connectionState = .failed(message)
                transientError = message
            }
        }
    }

    private func waitForHomeConnectOperation() async {
        guard homeConnectOperationInProgress else { return }
        await withCheckedContinuation { homeConnectWaiters.append($0) }
    }

    private func waitForOpenClaimMutation() async {
        guard isClosingOpenHomeClaims else { return }
        await withCheckedContinuation { homeClaimMutationWaiters.append($0) }
    }

    private func finishOpenClaimMutation() {
        isClosingOpenHomeClaims = false
        let waiters = homeClaimMutationWaiters
        homeClaimMutationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func finishHomeClaimLifecycleMutation() {
        homeClaimLifecycleMutationInProgress = false
        let waiters = homeClaimMutationWaiters
        homeClaimMutationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func finishHomeConnectOperation() {
        homeConnectOperationInProgress = false
        let waiters = homeConnectWaiters
        homeConnectWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private enum HomeClaimReleaseReason: String {
        case disconnect
        case startNew
        case switchConversation
        case lifecycle
        case staleOpen
        case userClose
    }

    private func isCurrentHomeOperation(_ generation: UInt64, profileID: UUID?) -> Bool {
        generation == homeLifecycleGeneration
            && isLifecycleActive
            && !homeOperationsSuppressed
            && (profileID == nil || profileID == activeProfileID)
    }

    @discardableResult
    private func releasePairedHomeClaim(
        _ claim: HomeConversationClaim,
        reason: HomeClaimReleaseReason,
        openedBinding: HomeConversationBinding?,
        bridgeClient: (any HomeBridgeSessionClient)? = nil
    ) async -> Bool {
        var released = false
        if let openedBinding, let bridgeClient,
           await bridgeClient.close(binding: openedBinding) == .closed {
            DiagnosticsJournal.shared.record("home claim released reason=\(reason.rawValue)")
            released = true
        }
        if !released, let claimRef = claim.claimRef, let homeClaimProvider {
            do {
                if let results = try await homeClaimProvider.closeClaims(
                    for: claim.profileID,
                    claimRefs: [claimRef]
                ), let result = results.first(where: { $0.claimRef == claimRef }),
                   result.result == .closed || result.result == .notOpen {
                    if result.result == .closed {
                        DiagnosticsJournal.shared.record("home claim released reason=\(reason.rawValue)")
                    }
                    released = true
                }
            } catch {
                // Keep the in-memory claim so another connect cannot duplicate it.
            }
        }
        if released {
            pendingHomeClaimsByProfile.removeValue(forKey: claim.profileID)
            if homeClaim?.profileID == claim.profileID,
               homeClaim?.conversationHandle == claim.conversationHandle {
                homeClaim = nil
            }
            if homeConversationBinding?.profileID == claim.profileID,
               homeConversationBinding?.conversationHandle == claim.conversationHandle {
                homeConversationBinding = nil
            }
            return true
        }
        pendingHomeClaimsByProfile[claim.profileID] = claim
        if activeProfileID == claim.profileID { homeClaim = claim }
        return false
    }

    private func connectHome(operationGeneration: UInt64) async {
        guard isCurrentHomeOperation(operationGeneration, profileID: activeProfileID) else { return }
        canContinueWithoutResendingHomeTurn = false
        homeReconnectConfirmsNoUnresolvedTurn = false
        let reopeningPairedClaim = homeClaimsPerConnect && homeClaim != nil
        if homeClaimsPerConnect, homeClaim == nil {
            guard await makePairedHomeClaim(operationGeneration: operationGeneration) else { return }
        }
        guard isCurrentHomeOperation(operationGeneration, profileID: activeProfileID),
              let claim = homeClaim,
              let homeClient else {
            if isCurrentHomeOperation(operationGeneration, profileID: activeProfileID) {
                let failure = HomeBridgeFailure.home(
                    code: .authorizationUnavailable,
                    phase: .open
                )
                homeBridgeState = .unavailable(failure)
                connectionState = .failed(failure.safeReason)
                transientError = "Home pairing is unavailable for this Hermes Profile."
            }
            return
        }

        if let recovery = homeRecovery, !recoveryMatches(recovery, claim: claim) {
            HomeConnectionTrace.localMismatch(site: "recovery_vs_claim_before_open")
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
        HomeConnectionTrace.open(outcome)
        guard isCurrentHomeOperation(operationGeneration, profileID: claim.profileID) else {
            let binding: HomeConversationBinding?
            if case .ready(let readyBinding, _) = outcome {
                binding = readyBinding
            } else {
                binding = nil
            }
            _ = await releasePairedHomeClaim(
                claim,
                reason: .disconnect,
                openedBinding: binding,
                bridgeClient: homeClient
            )
            return
        }

        switch outcome {
        case .ready(let binding, let capabilities):
            guard homeBinding(binding, matches: claim) else {
                HomeConnectionTrace.localMismatch(
                    site: "open_ready_vs_claim fields=\(homeBindingMismatchFields(binding, claim: claim))"
                )
                _ = await releasePairedHomeClaim(
                    claim,
                    reason: .staleOpen,
                    openedBinding: binding,
                    bridgeClient: homeClient
                )
                let failure = HomeBridgeFailure.home(code: .conversationMismatch, phase: .open)
                applyHomeConnectionFailure(failure, unavailable: true)
                return
            }
            if claim.routePinPending {
                homeClaim = claim.pinned(to: binding.route)
            }
            homeConversationBinding = binding
            if homeRecovery != nil {
                connectionState = .reconnecting(attempt: 1, of: reconnectPolicy.maxAttempts)
                await reconnectHome(
                    using: binding,
                    restoredTurn: homeTurnBinding,
                    client: homeClient,
                    operationGeneration: operationGeneration
                )
                return
            }
            presentHomeReadyState(
                binding: binding,
                capabilities: capabilities,
                client: homeClient
            )
            if let dividerText = pendingHomeDividerText {
                pendingHomeDividerText = nil
                await insertHomeDividerIfNeeded(dividerText)
            }
        case .unavailable(.reconnectRequired):
            guard let binding = reconnectBinding(for: claim) else {
                HomeConnectionTrace.localMismatch(site: "reconnect_required_without_binding")
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
                client: homeClient,
                operationGeneration: operationGeneration
            )
        case .unavailable(let failure):
            applyHomeConnectionFailure(failure, unavailable: true)
            if reopeningPairedClaim, homeRecovery == nil,
               failure.safeCode == .staleConversation,
               isCurrentHomeOperation(operationGeneration, profileID: claim.profileID) {
                await replaceEndedHomeClaim(claim, operationGeneration: operationGeneration)
            }
        case .disconnected(let failure):
            applyHomeConnectionFailure(failure, unavailable: false)
            scheduleHomeConnectRetry(after: failure, operationGeneration: operationGeneration)
        }
    }

    /// Home refused the held claim as ended and no turn is unresolved: release
    /// it where Home can confirm, then make one fresh claim.
    private func replaceEndedHomeClaim(
        _ claim: HomeConversationClaim,
        operationGeneration: UInt64
    ) async {
        guard await releaseEndedHomeClaim(claim),
              isCurrentHomeOperation(operationGeneration, profileID: claim.profileID) else { return }
        await connectHome(operationGeneration: operationGeneration)
    }

    private func releaseEndedHomeClaim(_ claim: HomeConversationClaim) async -> Bool {
        guard claim.claimRef != nil else {
            homeClaim = nil
            pendingHomeClaimsByProfile.removeValue(forKey: claim.profileID)
            return true
        }
        return await releasePairedHomeClaim(claim, reason: .staleOpen, openedBinding: nil)
    }

    /// The held claim that a `stale_conversation` reconnect refusal ended, when
    /// it may be replaced: a paired claim with no unresolved turn to protect.
    private func endedHomeClaim(
        after failure: HomeBridgeFailure,
        binding: HomeConversationBinding
    ) -> HomeConversationClaim? {
        guard homeClaimsPerConnect, homeRecovery == nil,
              failure.safeCode == .staleConversation,
              let claim = homeClaim,
              claim.profileID == binding.profileID,
              claim.conversationHandle == binding.conversationHandle else { return nil }
        return claim
    }

    private static func isRetryableTransportFailure(_ failure: HomeBridgeFailure) -> Bool {
        guard case .home(let code, let phase) = failure, phase != .lifecycle else { return false }
        return code == .transportUnavailable || code == .transportTimeout
    }

    /// Schedules the next connect on the reconnect policy's ladder. Each retry
    /// only reopens the held claim or reconnects its conversation; it never
    /// resubmits a prompt.
    private func scheduleHomeConnectRetry(
        after failure: HomeBridgeFailure,
        operationGeneration: UInt64
    ) {
        guard Self.isRetryableTransportFailure(failure),
              homeConnectRetryTask == nil,
              let profileID = activeProfileID,
              isCurrentHomeOperation(operationGeneration, profileID: profileID) else { return }
        let start = homeClock.now()
        let deadline = homeConnectRetryDeadline
            ?? start.advanced(by: homeOperationDeadlines.reconnectOverall)
        let attempt = homeConnectRetryAttempt + 1
        guard start < deadline,
              let delay = reconnectPolicy.delayNanoseconds(forAttempt: attempt) else { return }
        homeConnectRetryDeadline = deadline
        homeConnectRetryAttempt = attempt
        connectionState = .reconnecting(attempt: attempt, of: reconnectPolicy.maxAttempts)
        let wakeAt = min(start.advanced(by: .nanoseconds(Int64(delay))), deadline)
        homeConnectRetryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.homeClock.sleep(until: wakeAt)
            } catch { return }
            guard !Task.isCancelled,
                  self.isCurrentHomeOperation(operationGeneration, profileID: profileID) else { return }
            self.homeConnectRetryTask = nil
            await self.performConnect()
        }
    }

    private func cancelHomeConnectRetry() {
        if homeConnectRetryTask != nil, case .reconnecting = connectionState {
            connectionState = .disconnected
        }
        homeConnectRetryTask?.cancel()
        homeConnectRetryTask = nil
        homeConnectRetryAttempt = 0
        homeConnectRetryDeadline = nil
    }

    private func reconnectHome(
        using binding: HomeConversationBinding,
        restoredTurn: HomeTurnBinding?,
        client: any HomeBridgeSessionClient,
        operationGeneration: UInt64
    ) async {
        canContinueWithoutResendingHomeTurn = false
        homeReconnectConfirmsNoUnresolvedTurn = false
        let reconnectOutcome = await client.reconnect(binding: binding)
        guard isCurrentHomeOperation(operationGeneration, profileID: binding.profileID) else {
            if let claim = homeClaim, claim.profileID == binding.profileID {
                _ = await releasePairedHomeClaim(
                    claim,
                    reason: .disconnect,
                    openedBinding: binding,
                    bridgeClient: client
                )
            }
            return
        }
        HomeConnectionTrace.reconnect(reconnectOutcome)
        switch reconnectOutcome {
        case .ready(
            let readyBinding,
            let unresolvedTurn,
            let confirmsNoUnresolvedTurn
        ):
            guard Self.isSameConversation(readyBinding, binding) else {
                HomeConnectionTrace.localMismatch(
                    site: "reconnect_ready_vs_binding fields=\(Self.bindingDifferences(readyBinding, binding))"
                )
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
            homeReconnectConfirmsNoUnresolvedTurn = unresolvedTurn == nil
                && confirmsNoUnresolvedTurn
            refreshHomeContinueWithoutResendingEligibility()
            await persistConversation()
        case .unavailable(let failure):
            applyHomeConnectionFailure(failure, unavailable: true)
            if let claim = endedHomeClaim(after: failure, binding: binding),
               isCurrentHomeOperation(operationGeneration, profileID: claim.profileID) {
                homeConversationBinding = nil
                await replaceEndedHomeClaim(claim, operationGeneration: operationGeneration)
            }
        case .disconnected(let failure):
            applyHomeConnectionFailure(failure, unavailable: false)
            scheduleHomeConnectRetry(after: failure, operationGeneration: operationGeneration)
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
        homeConnectRetryAttempt = 0
        homeConnectRetryDeadline = nil
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
            && claim.accepts(route: recovery.route)
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
            && claim.accepts(route: binding.route)
            && binding.householdBinding == claim.approvedRoute.householdBinding
    }

    /// Names of the checks `homeBinding(_:matches:)` fails, for diagnostics.
    private func homeBindingMismatchFields(
        _ binding: HomeConversationBinding,
        claim: HomeConversationClaim
    ) -> String {
        var fields: [String] = []
        if binding.profileID != activeProfileID { fields.append("active_profile") }
        if binding.profileID != claim.profileID { fields.append("claim_profile") }
        if binding.conversationHandle != claim.conversationHandle { fields.append("handle") }
        if binding.endpoint != claim.approvedRoute.endpoint { fields.append("endpoint") }
        if !claim.accepts(route: binding.route) { fields.append("route") }
        if binding.householdBinding != claim.approvedRoute.householdBinding {
            fields.append("household")
        }
        return fields.joined(separator: ",")
    }

    /// Whether Home's reconnect names the same conversation; see
    /// `HomeConversationBinding.isSameConversation(as:)`.
    nonisolated static func isSameConversation(
        _ lhs: HomeConversationBinding,
        _ rhs: HomeConversationBinding
    ) -> Bool {
        lhs.isSameConversation(as: rhs)
    }

    /// Names of the fields that differ between two bindings, for diagnostics.
    nonisolated static func bindingDifferences(
        _ lhs: HomeConversationBinding,
        _ rhs: HomeConversationBinding
    ) -> String {
        var fields = lhs.identityDifferences(from: rhs)
        if lhs.capabilities != rhs.capabilities { fields.append("capabilities") }
        return fields.joined(separator: ",")
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
        homeReconnectConfirmsNoUnresolvedTurn = false
        canContinueWithoutResendingHomeTurn = false
        sessionMetadata = nil
        sessionStartedAt = nil
        activityText = nil
        transientError = failure.safeReason
        if homeClaimsPerConnect, unavailable, failure != .reconnectRequired {
            // Keep the claim reference in memory until Home confirms release;
            // dropping it here would let the next Connect create a duplicate.
            pendingHomeDividerText = nil
            canStartNewHomeConversation = homeRecovery != nil || homeClaim != nil
            if homeRecovery != nil { presentHomeContinuityLost() }
        }
    }

    // MARK: - Paired personal clients

    /// One fresh claim per connect; stale responses are released or retained
    /// in memory so they can never trigger a parallel creation.
    private func makePairedHomeClaim(operationGeneration: UInt64) async -> Bool {
        guard homeRecovery == nil else {
            presentHomeContinuityLost()
            return false
        }
        guard let profileID = activeProfileID, let homeClaimProvider else {
            applyPairedClaimFailure(
                message: "Home pairing is unavailable for this Hermes Profile.",
                failure: .home(code: .authorizationUnavailable, phase: .authorization)
            )
            return false
        }
        if let pending = pendingHomeClaimsByProfile.removeValue(forKey: profileID) {
            homeClaim = pending
            recordClaimedHomeSession(pending, choice: .mostRecent, chosenTitle: nil)
            return true
        }
        if let retryAfter = ambiguousClaimCreationRetryAfter[profileID] {
            guard homeClock.now() >= retryAfter else {
                applyPairedClaimFailure(
                    message: "Home may have created a conversation but its response was lost. Wait for that claim to expire on Home before connecting again.",
                    failure: .home(code: .transportUnavailable, phase: .authorization)
                )
                return false
            }
            ambiguousClaimCreationRetryAfter.removeValue(forKey: profileID)
        }

        homeBridgeState = .connecting
        connectionState = .connecting
        transientError = nil
        var sessionChoice = nextHomeSessionChoice
        let chosenTitle = pendingHomeSessionTitle
        nextHomeSessionChoice = .mostRecent
        pendingHomeSessionTitle = nil
        do {
            let provided: HomeConversationClaim?
            do {
                provided = try await homeClaimProvider.conversationClaim(
                    for: profileID,
                    session: sessionChoice
                )
            } catch HomeClientConnectError.denied(let denial)
                where sessionChoice == .mostRecent
                    && (denial == .sessionBusy || denial == .sessionUnavailable) {
                guard isCurrentHomeOperation(operationGeneration, profileID: profileID) else {
                    return false
                }
                sessionChoice = .new
                provided = try await homeClaimProvider.conversationClaim(
                    for: profileID,
                    session: .new
                )
            }
            guard let claim = provided else {
                if isCurrentHomeOperation(operationGeneration, profileID: profileID) {
                    applyPairedClaimFailure(
                        message: "Home pairing is unavailable for this Hermes Profile.",
                        failure: .home(code: .authorizationUnavailable, phase: .authorization)
                    )
                }
                return false
            }
            DiagnosticsJournal.shared.record("home claim created")
            guard isCurrentHomeOperation(operationGeneration, profileID: profileID) else {
                _ = await releasePairedHomeClaim(
                    claim,
                    reason: .disconnect,
                    openedBinding: nil
                )
                return false
            }
            homeClaim = claim
            canManageOpenHomeClaims = claim.claimRef != nil
            shouldOfferManageOpenHomeClaims = false
            ambiguousClaimCreationRetryAfter.removeValue(forKey: profileID)
            recordClaimedHomeSession(claim, choice: sessionChoice, chosenTitle: chosenTitle)
            canStartNewHomeConversation = false
            if homeClient == nil {
                homeClient = (homeClientFactory ?? UnavailableHomeBridgeSessionClientFactory())
                    .make(profileID: profileID, mode: .home)
            }
            homeRouteState = HomeRouteState(
                status: .unattempted,
                identity: claim.approvedRoute.identity,
                failure: nil
            )
            return true
        } catch {
            guard isCurrentHomeOperation(operationGeneration, profileID: profileID) else {
                if Self.isAmbiguousClaimCreation(error) {
                    ambiguousClaimCreationRetryAfter[profileID] =
                        homeClock.now().advanced(by: Self.ambiguousClaimRetryDelay)
                }
                abandonPairedClaimAttempt()
                return false
            }
            if Self.isAmbiguousClaimCreation(error) {
                ambiguousClaimCreationRetryAfter[profileID] =
                    homeClock.now().advanced(by: Self.ambiguousClaimRetryDelay)
            }
            let connectError = error as? HomeClientConnectError
            if let connectError, case .denied(.claimLimit) = connectError {
                let supported = await homeClaimProvider.supportsClaimManagement(for: profileID)
                guard isCurrentHomeOperation(operationGeneration, profileID: profileID) else { return false }
                canManageOpenHomeClaims = supported
                shouldOfferManageOpenHomeClaims = supported
            }
            applyPairedClaimFailure(
                message: connectError?.errorDescription
                    ?? "Home did not grant a conversation. Connect again.",
                failure: connectError?.failure
                    ?? .home(code: .authorizationUnavailable, phase: .authorization)
            )
            return false
        }
    }

    private static func isAmbiguousClaimCreation(_ error: Error) -> Bool {
        guard let error = error as? HomeClientConnectError else { return true }
        switch error {
        case .homeUnreachable, .invalidResponse:
            return true
        case .pairAgain, .denied, .credentialUnavailable:
            return false
        }
    }

    /// Remembers the claim's session and chooses the divider shown once it is
    /// ready: none when the same session continues, "New conversation" for a
    /// new one, and "Resumed: <title>" for a session chosen from the list.
    private func recordClaimedHomeSession(
        _ claim: HomeConversationClaim,
        choice: HomeClientSessionChoice,
        chosenTitle: String?
    ) {
        guard let claimed = claim.claimedSession else {
            // A provider without client sessions: every claim is new.
            homeSession = nil
            pendingHomeDividerText = Self.newHomeConversationDividerText
            return
        }
        let previous = homeSession
        guard claimed.resumed else {
            homeSession = HomeCurrentSession(sessionRef: claimed.sessionRef, title: nil)
            pendingHomeDividerText = Self.newHomeConversationDividerText
            return
        }
        let sameSession = previous?.sessionRef != nil && previous?.sessionRef == claimed.sessionRef
        let title = chosenTitle ?? (sameSession ? previous?.title : nil)
        homeSession = HomeCurrentSession(sessionRef: claimed.sessionRef, title: title)
        if case .resume = choice {
            pendingHomeDividerText = Self.resumedHomeSessionDividerText(title: chosenTitle)
        } else if sameSession || previous == nil || previous?.sessionRef == nil {
            // Continuing where this client left off, the first connect after
            // launch, or a new session whose reference was never looked up
            // (Home names it at the first turn, so it is almost always the
            // latest): the local transcript already leads here.
            pendingHomeDividerText = nil
        } else {
            pendingHomeDividerText = Self.resumedLatestHomeSessionDividerText
        }
    }

    /// The attempt was superseded (lifecycle or profile change) while the
    /// claim was in flight; do not leave `connect()` locked out.
    private func abandonPairedClaimAttempt() {
        guard connectionState == .connecting else { return }
        connectionState = .disconnected
        homeBridgeState = .disconnected(.home(code: .transportUnavailable, phase: .lifecycle))
    }

    private func applyPairedClaimFailure(message: String, failure: HomeBridgeFailure) {
        homeBridgeState = .disconnected(failure)
        connectionState = .disconnected
        sessionMetadata = nil
        sessionStartedAt = nil
        activityText = nil
        transientError = message
    }

    private func presentHomeContinuityLost() {
        homeBridgeState = .disconnected(.home(code: .staleConversation, phase: .reconnect))
        connectionState = .disconnected
        sessionMetadata = nil
        sessionStartedAt = nil
        canContinueWithoutResendingHomeTurn = false
        canStartNewHomeConversation = true
        transientError = "Home can no longer resume the earlier conversation. Its last prompt was not resent. Start a new conversation to continue."
    }

    /// The user's deliberate choice after continuity was lost. Earlier local
    /// messages stay; nothing is resent to Hermes.
    @discardableResult
    func startNewHomeConversation() async -> Bool {
        guard isHomeMode, homeClaimsPerConnect, canStartNewHomeConversation,
              !isSending, !homeConnectOperationInProgress else {
            return false
        }
        let promptToKeep = unconfirmedTurnText
        canStartNewHomeConversation = false
        await disconnect()
        guard homeClaim == nil else {
            transientError = "Home could not confirm that the previous conversation closed. Try again before starting a new one."
            canStartNewHomeConversation = true
            return false
        }
        homeRecovery = nil
        homeTurnBinding = nil
        homeTurnDeliveryState = .idle
        unconfirmedTurnText = nil
        homeConversationBinding = nil
        homeJoinTimeout = nil
        activeTurnGeneration = nil
        activeTurnText = nil
        transientError = nil
        if let promptToKeep {
            if messages.last(where: { $0.role == .user })?.text != promptToKeep {
                messages.append(TranscriptMessage(role: .user, text: promptToKeep))
            }
            messages.append(TranscriptMessage(
                role: .error,
                text: "The earlier prompt may not have reached Hermes. It was not resent."
            ))
        }
        await persistConversation()
        await connect()
        return connectionState.isConnected
    }

    /// The unconfirmed prompt to offer for recovery (Resend), only when a
    /// turn is genuinely unresolved. `unconfirmedTurnText` is also the
    /// crash-safety marker written as soon as a prompt is sent, so showing
    /// it directly made every normal send look like a failure.
    var unresolvedTurnTextForDisplay: String? {
        guard let text = unconfirmedTurnText else { return nil }
        if isHomeMode {
            switch homeTurnDeliveryState {
            case .uncertain, .failedKnown, .idle:
                return isSending ? nil : text
            case .awaitingAcceptance, .accepted, .completed, .interrupted:
                return nil
            }
        }
        return isSending ? nil : text
    }

    // MARK: Home client sessions

    /// A paired Home profile whose claims name Hermes sessions.
    var supportsHomeSessions: Bool {
        isHomeMode && homeClaimsPerConnect && homeSession != nil
    }

    var currentHomeClaimRef: String? { homeClaim?.claimRef }
    var supportsOpenHomeClaims: Bool {
        isHomeMode && homeClaimsPerConnect && canManageOpenHomeClaims
    }

    /// Why the session cannot be switched right now, or nil.
    var homeSessionSwitchBlockedReason: String? {
        if isSending || activeTurnText != nil {
            return "Finish the current turn before switching conversations."
        }
        if homeRecovery != nil || unconfirmedTurnText != nil {
            return "Resolve the unconfirmed turn before switching conversations."
        }
        if !connectionState.isConnected {
            return "Connect to Home before switching conversations."
        }
        return nil
    }

    /// Renaming uses Hermes's own `title` command, only when advertised and
    /// once the session has a reference (after its first accepted turn).
    var canRenameHomeSession: Bool {
        guard supportsHomeSessions,
              homeSession?.sessionRef != nil,
              let binding = homeConversationBinding else { return false }
        return binding.capabilities.commands.contains("title")
    }

    /// The Profile's sessions, newest first. A late response cannot update a
    /// different Profile or claim.
    func loadHomeSessions() async throws -> [HomeClientSessionSummary] {
        guard supportsHomeSessions,
              let profileID = activeProfileID,
              let homeClaimProvider else {
            return []
        }
        let generation = homeLifecycleGeneration
        let claimHandle = homeClaim?.conversationHandle
        if homeSession?.sessionRef == nil, let claimHandle,
           let sessionRef = try? await homeClaimProvider.clientSessionRef(
               for: profileID,
               conversationHandle: claimHandle
           ),
           isCurrentHomeOperation(generation, profileID: profileID),
           homeClaim?.conversationHandle == claimHandle {
            homeSession?.sessionRef = sessionRef
        }
        let sessions = try await homeClaimProvider.clientSessions(for: profileID) ?? []
        guard isCurrentHomeOperation(generation, profileID: profileID) else { return [] }
        if let sessionRef = homeSession?.sessionRef,
           let current = sessions.first(where: { $0.sessionRef == sessionRef }) {
            homeSession?.title = current.title.isEmpty ? nil : current.title
        }
        return sessions
    }

    /// Loads the device-wide list immediately; title enrichment is detached
    /// and best-effort so it never delays claim cleanup.
    func loadOpenHomeClaims() async {
        guard isHomeMode,
              let profileID = activeProfileID,
              let homeClaimProvider else {
            canManageOpenHomeClaims = false
            openHomeClaimList = nil
            openHomeClaimTitles = [:]
            return
        }
        let lifecycleGeneration = homeLifecycleGeneration
        openHomeClaimsGeneration &+= 1
        let listGeneration = openHomeClaimsGeneration
        openHomeClaimsError = nil
        do {
            let supported = await homeClaimProvider.supportsClaimManagement(for: profileID)
            guard isCurrentHomeOperation(lifecycleGeneration, profileID: profileID),
                  openHomeClaimsGeneration == listGeneration else { return }
            guard supported else {
                canManageOpenHomeClaims = false
                openHomeClaimList = nil
                openHomeClaimTitles = [:]
                return
            }
            canManageOpenHomeClaims = true
            let listResult = try await homeClaimProvider.openClaims(for: profileID)
            guard isCurrentHomeOperation(lifecycleGeneration, profileID: profileID),
                  openHomeClaimsGeneration == listGeneration else { return }
            guard let list = listResult else {
                canManageOpenHomeClaims = false
                openHomeClaimList = nil
                openHomeClaimTitles = [:]
                return
            }
            openHomeClaimList = list
            openHomeClaimTitles = [:]
            Task { @MainActor [weak self] in
                let titles = await homeClaimProvider.claimTitles(for: profileID, claims: list.claims)
                let stillSupported = await homeClaimProvider.supportsClaimManagement(for: profileID)
                guard let self,
                      self.isCurrentHomeOperation(lifecycleGeneration, profileID: profileID),
                      self.openHomeClaimsGeneration == listGeneration,
                      stillSupported else {
                    return
                }
                self.openHomeClaimTitles = titles
            }
        } catch {
            guard isCurrentHomeOperation(lifecycleGeneration, profileID: profileID),
                  openHomeClaimsGeneration == listGeneration else { return }
            let stillSupported = await homeClaimProvider.supportsClaimManagement(for: profileID)
            guard isCurrentHomeOperation(lifecycleGeneration, profileID: profileID),
                  openHomeClaimsGeneration == listGeneration else { return }
            canManageOpenHomeClaims = stillSupported
            guard stillSupported else {
                openHomeClaimList = nil
                openHomeClaimTitles = [:]
                openHomeClaimsError = nil
                return
            }
            openHomeClaimsError = "Home could not load open conversations. Try again."
        }
    }

    func closeOpenHomeClaim(_ claimRef: String) async {
        guard let profileID = activeProfileID,
              openHomeClaimList?.claims.contains(where: { $0.claimRef == claimRef }) == true,
              claimRef != homeClaim?.claimRef else {
            return
        }
        await closeOpenHomeClaims([claimRef], profileID: profileID)
    }

    func closeAllOtherOpenHomeClaims() async {
        guard let profileID = activeProfileID, let list = openHomeClaimList else { return }
        let currentClaimRef = homeClaim?.claimRef
        let refs = list.claims.map(\.claimRef).filter { $0 != currentClaimRef }
        await closeOpenHomeClaims(refs, profileID: profileID)
    }

    private func closeOpenHomeClaims(_ requestedRefs: [String], profileID: UUID) async {
        guard !requestedRefs.isEmpty,
              !isClosingOpenHomeClaims,
              !homeClaimLifecycleMutationInProgress,
              canManageOpenHomeClaims,
              let homeClaimProvider else {
            return
        }
        let lifecycleGeneration = homeLifecycleGeneration
        isClosingOpenHomeClaims = true
        openHomeClaimsGeneration &+= 1
        defer { finishOpenClaimMutation() }

        var offset = 0
        while offset < requestedRefs.count {
            guard isCurrentHomeOperation(lifecycleGeneration, profileID: profileID) else { return }
            let end = min(offset + 64, requestedRefs.count)
            let currentClaimRef = homeClaim?.claimRef
            let batch = requestedRefs[offset..<end].filter { $0 != currentClaimRef }
            offset = end
            guard !batch.isEmpty else { continue }
            do {
                let closeResult = try await homeClaimProvider.closeClaims(
                    for: profileID,
                    claimRefs: batch
                )
                guard isCurrentHomeOperation(lifecycleGeneration, profileID: profileID) else { return }
                guard let results = closeResult else {
                    canManageOpenHomeClaims = false
                    openHomeClaimList = nil
                    openHomeClaimTitles = [:]
                    return
                }
                for result in results where result.result == .closed {
                    DiagnosticsJournal.shared.record("home claim released reason=userClose")
                }
            } catch {
                await loadOpenHomeClaims()
                guard isCurrentHomeOperation(lifecycleGeneration, profileID: profileID) else { return }
                openHomeClaimsError = "Home did not confirm the close. The list was refreshed; close again only if the conversation is still open."
                return
            }
        }
        await loadOpenHomeClaims()
    }

    /// Closes the current claim and continues in a new Hermes session.
    @discardableResult
    func startNewHomeSession() async -> Bool {
        await switchHomeSession(to: .new, title: nil)
    }

    /// Closes the current claim and continues in `session`. A session held
    /// by another claim is refused here without closing anything.
    @discardableResult
    func resumeHomeSession(_ session: HomeClientSessionSummary) async -> Bool {
        guard session.sessionRef != homeSession?.sessionRef else { return true }
        guard !session.active else {
            transientError = HomeClientConnectError.denied(.sessionBusy).errorDescription
            return false
        }
        return await switchHomeSession(
            to: .resume(sessionRef: session.sessionRef),
            title: session.title
        )
    }

    /// Renames the current session through Hermes's `title` command.
    @discardableResult
    func renameHomeSession(to title: String) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canRenameHomeSession else { return false }
        switch await dispatchHomeCommand(name: "title", argument: trimmed) {
        case .completed:
            homeSession?.title = trimmed
            return true
        case .rejected, .uncertain:
            transientError = "Hermes did not rename this conversation. Try again."
            return false
        }
    }

    /// One claim, one session: release the current claim before making a new
    /// one. Nothing is resent.
    private func switchHomeSession(
        to choice: HomeClientSessionChoice,
        title: String?
    ) async -> Bool {
        guard supportsHomeSessions else { return false }
        if let reason = homeSessionSwitchBlockedReason {
            transientError = reason
            return false
        }
        await disconnect()
        guard homeClaim == nil else {
            transientError = "Home could not confirm that the previous conversation closed. Try again before switching."
            return false
        }
        nextHomeSessionChoice = choice
        pendingHomeSessionTitle = title
        await connect()
        if connectionState.isConnected { return true }
        guard case .resume = choice else { return false }
        let refusal = transientError
        await connect()
        if connectionState.isConnected {
            transientError = [refusal, "Continued the latest conversation instead."]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        return false
    }

    /// Disconnect releases the claim before dropping its handle. An unopened
    /// claim uses HOME-NW-18; an opened claim prefers `conversation.close`.
    func disconnect() async {
        guard !isSending else {
            transientError = "Stop the current turn before disconnecting."
            return
        }
        homeLifecycleGeneration &+= 1
        openHomeClaimsGeneration &+= 1
        homeClaimLifecycleMutationInProgress = true
        defer { finishHomeClaimLifecycleMutation() }
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelHomeConnectRetry()
        await waitForHomeConnectOperation()
        await waitForOpenClaimMutation()

        if transportMode == .home {
            let released = await closePairedHomeConversation(reason: .disconnect)
            await closeHomeClient()
            homeBridgeState = .disconnected(.home(code: .transportUnavailable, phase: .lifecycle))
            if !released {
                transientError = "Home could not confirm that the conversation closed. Reconnect before starting another."
            }
        } else {
            isExpectedDisconnect = true
            await client.disconnect()
            isExpectedDisconnect = false
        }
        connectionState = .disconnected
        sessionMetadata = nil
        sessionStartedAt = nil
        activityText = nil
        didAttemptAutomaticConnection = true
    }

    @discardableResult
    private func closePairedHomeConversation(
        reason: HomeClaimReleaseReason = .disconnect
    ) async -> Bool {
        guard homeClaimsPerConnect, let claim = homeClaim else { return true }
        let binding = homeConversationBinding?.profileID == claim.profileID
            ? homeConversationBinding
            : nil
        let released = await releasePairedHomeClaim(
            claim,
            reason: reason,
            openedBinding: binding,
            bridgeClient: homeClient
        )
        if released { pendingHomeDividerText = nil }
        return released
    }

    /// Marks where the conversation continues in a different Hermes session.
    /// Consecutive switches without messages keep only the latest divider.
    private func insertHomeDividerIfNeeded(_ text: String) async {
        guard !messages.isEmpty else { return }
        if let last = messages.last, last.role == .system, Self.isHomeDivider(last.text) {
            guard last.text != text else { return }
            messages.removeLast()
        }
        guard !messages.isEmpty else { return }
        messages.append(TranscriptMessage(role: .system, text: text))
        await persistConversation()
    }

    private static func isHomeDivider(_ text: String) -> Bool {
        text == newHomeConversationDividerText
            || text == resumedLatestHomeSessionDividerText
            || text == resumedHomeSessionDividerText(title: nil)
            || text.hasPrefix("Resumed: ")
    }

    /// A paired claim's handle never reaches disk; recovery records carry a
    /// placeholder instead.
    private func persistableHomeRecovery(
        _ recovery: PersistedHomeRecovery?
    ) -> PersistedHomeRecovery? {
        guard homeClaimsPerConnect, let recovery else { return recovery }
        return recovery.replacingHandle(PersistedHomeRecovery.redactedHandle)
    }

    /// Restores the in-memory handle when the app only left the foreground
    /// and the same claim is still held. After a relaunch it stays redacted,
    /// which reports lost continuity rather than replaying the turn.
    private func restoredHomeRecovery(
        _ recovery: PersistedHomeRecovery?
    ) -> PersistedHomeRecovery? {
        guard let recovery,
              recovery.conversationHandle == PersistedHomeRecovery.redactedHandle else {
            return recovery
        }
        guard let claim = homeClaim,
              claim.profileID == recovery.profileID,
              claim.approvedRoute.endpoint == recovery.endpoint,
              claim.accepts(route: recovery.route) else {
            return recovery
        }
        return recovery.replacingHandle(claim.conversationHandle)
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
                guard isCurrentHomeEvent(standard.scope) else { return }
                apply(event)
                if let homeEventHandler { await homeEventHandler(event) }
                guard isCurrentHomeEvent(standard.scope) else { return }
                if case .turnComplete = event {
                    finishHomeControlTurn(success: true)
                } else if case .turnInterrupted = event {
                    finishHomeControlTurn(success: false)
                }
            }
            restartHomeControlIdle()
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
            restartHomeControlIdle()
            for event in homeNormalizer.normalizeHomeAudio(event) {
                if let homeEventHandler { await homeEventHandler(event) }
            }
        case .binaryPCM(let scope, let data):
            guard isCurrentHomeEvent(scope),
                  !homeAudioTerminal,
                  !homeAudioTerminalProcessing,
                  !data.isEmpty else { return }
            homeAudioLastReceivedAt = homeClock.now()
            restartHomeControlIdle()
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
            guard isCurrentHomeEvent(scope) else { return }
            homeAudioTerminalProcessing = false
            homeAudioTerminal = true
            resumeHomeAudioTerminalWaiter()
            refreshHomeContinueWithoutResendingEligibility()
            restartHomeControlIdle()
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
            restartHomeControlIdle()
        case .command(let command):
            guard command.conversationHandle == binding.conversationHandle else { return }
            homeCommandEvents.append(command)
            if homeCommandEvents.count > 20 { homeCommandEvents.removeFirst() }
        case .activity(let scope, let activity):
            if let scope, !isCurrentHomeEvent(scope) { return }
            activityText = activity == .idle || activity == .stopped ? nil : activity.rawValue
            if scope != nil { restartHomeControlIdle() }
        case .turnAlive(let scope, let phase):
            guard isCurrentHomeEvent(scope) else { return }
            homeKeepaliveAwaitingInput = phase == .awaitingInput
            restartHomeControlIdle()
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
        if success {
            // Standard synthesizes reply audio only once the text completes,
            // so the audio-start deadline runs from here, not from acceptance.
            if !homeAudioRequested, !homeAudioTerminal, !homeAudioTerminalProcessing {
                scheduleHomeAudioStartDeadline(for: turn)
            }
        } else {
            homeAudioTerminal = true
            resumeHomeAudioTerminalWaiter()
        }
        cancelHomeControlDeadlines()
        homeTurnDeliveryState = success ? .completed(turn) : .interrupted(turn)
        homeTurnResult = (turn, success)
        resumeHomeTurnWaiters(returning: success, for: turn)
    }

    /// Without keep-alives, the turn has `controlTerminal` from acceptance to
    /// finish. With keep-alives, it may run for `controlBackstop` as long as
    /// it is never silent for `controlIdle`; a pending prompt pauses the idle
    /// clock because the turn is waiting on the user, not stuck.
    private func scheduleHomeControlDeadline(for turn: HomeTurnBinding) {
        cancelHomeControlDeadlines()
        homeTurnUsesKeepalive = homeConversationBinding?.capabilities.turnKeepalive ?? false
        homeKeepaliveAwaitingInput = false
        let limit = homeTurnUsesKeepalive
            ? homeTurnAudioDeadlines.controlBackstop
            : homeTurnAudioDeadlines.controlTerminal
        homeControlTimeoutTask = homeControlExpiryTask(
            for: turn,
            at: homeClock.now().advanced(by: limit)
        )
        restartHomeControlIdle()
    }

    private func restartHomeControlIdle() {
        homeControlIdleTask?.cancel()
        homeControlIdleTask = nil
        guard homeTurnUsesKeepalive,
              let turn = homeTurnBinding,
              !homeControlTerminal,
              pendingHomePrompt == nil,
              !homeKeepaliveAwaitingInput else { return }
        homeControlIdleTask = homeControlExpiryTask(
            for: turn,
            at: homeClock.now().advanced(by: homeTurnAudioDeadlines.controlIdle)
        )
    }

    private func cancelHomeControlDeadlines() {
        homeControlTimeoutTask?.cancel()
        homeControlTimeoutTask = nil
        homeControlIdleTask?.cancel()
        homeControlIdleTask = nil
    }

    private func homeControlExpiryTask(
        for turn: HomeTurnBinding,
        at deadline: ContinuousClock.Instant
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await self?.homeClock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self,
                  self.homeTurnBinding == turn,
                  !self.homeControlTerminal else { return }
            self.cancelHomeControlDeadlines()
            self.homeJoinTimeout = .controlTerminalMissing
            DiagnosticsJournal.shared.record("store Home deadline expired kind=controlTerminalMissing")
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
            self.resumeHomeTurnWaiters(returning: false, for: turn)
        }
    }

    /// Home streams speech at about real time, so a long reply's audio can
    /// take well over `audioTerminal` to arrive. The deadline is for silence:
    /// it runs from the latest audio received, not from `audio_start`.
    private func scheduleHomeAudioDeadline(for turn: HomeTurnBinding?) {
        guard let turn else { return }
        homeAudioTimeoutTask?.cancel()
        homeAudioLastReceivedAt = homeClock.now()
        homeAudioTimeoutTask = Task { [weak self] in
            while true {
                guard let lastReceived = self?.homeAudioLastReceivedAt,
                      let silence = self?.homeTurnAudioDeadlines.audioTerminal else { return }
                do {
                    try await self?.homeClock.sleep(until: lastReceived.advanced(by: silence))
                } catch {
                    return
                }
                guard let latest = self?.homeAudioLastReceivedAt, latest > lastReceived else { break }
            }
            guard let self,
                  self.homeTurnBinding == turn else { return }
            guard case .streaming = self.homeAudioState,
                  !self.homeAudioTerminal,
                  !self.homeAudioTerminalProcessing else { return }
            self.homeJoinTimeout = .audioTerminalMissing
            DiagnosticsJournal.shared.record("store Home deadline expired kind=audioTerminalMissing")
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
            DiagnosticsJournal.shared.record("store Home deadline expired kind=audioStartMissing")
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
        let turn = homeTurnBinding
        homeAudioState = state
        homeAudioTerminalProcessing = true
        if let homeEventHandler {
            await homeEventHandler(.audioAbort(
                turnID: homeTurnBinding?.turnID ?? "home",
                reason: reason
            ))
        }
        guard homeTurnBinding == turn else { return }
        homeAudioTerminalProcessing = false
        homeAudioTerminal = true
        resumeHomeAudioTerminalWaiter()
        refreshHomeContinueWithoutResendingEligibility()
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
        canContinueWithoutResendingHomeTurn = false
        homeReconnectConfirmsNoUnresolvedTurn = false
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
            let completed = await waitForHomeTurnCompletion(turn: turn)
            if completed, eventHandler != nil {
                await waitForHomeAudioTerminal(turn: turn)
            }
            guard homeTurnBinding == turn else { return completed }
            DiagnosticsJournal.shared.record(
                "store Home sendTurn returning completed=\(completed) audio_terminal=\(homeAudioTerminal) audio_requested=\(homeAudioRequested)"
            )
            homeEventHandler = nil
            activeTurnText = nil
            if !completed {
                if case .interrupted = homeTurnDeliveryState {
                    await completeHomeTurnAfterAudio(for: turn)
                    return false
                }
                activityText = nil
                isSending = false
                await persistConversation()
                return false
            }
            // Voice playback owns the final drain. Text-only callers can
            // explicitly settle through completeHomeTurnAfterAudio(for:).
            if eventHandler == nil {
                await completeHomeTurnAfterAudio(for: turn)
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
        if let homeTurnResult, homeTurnResult.turn == turn { return homeTurnResult.completed }
        guard homeTurnBinding == turn else { return false }
        return await withCheckedContinuation { continuation in
            homeTurnWaiters.append((turn, continuation))
        }
    }

    private func resumeHomeTurnWaiters(returning result: Bool, for turn: HomeTurnBinding? = nil) {
        for waiter in homeTurnWaiters where turn == nil || waiter.turn == turn {
            waiter.continuation.resume(returning: result)
        }
        homeTurnWaiters.removeAll { turn == nil || $0.turn == turn }
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
        DiagnosticsJournal.shared.record(
            "store Home submission marked uncertain; closing Home client \(failure.diagnosticSummary)"
        )
        canContinueWithoutResendingHomeTurn = false
        homeReconnectConfirmsNoUnresolvedTurn = false
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
        cancelHomeControlDeadlines()
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
        // The prompt stays unconfirmed for the user; only the transport is retried.
        scheduleHomeConnectRetry(after: failure, operationGeneration: homeLifecycleGeneration)
    }

    /// Playback owns the last part of a Home turn. The control terminal is
    /// known before native audio has necessarily drained, so this is the only
    /// method allowed to clear the persisted accepted binding.
    func completeHomeTurnAfterAudio(for turn: HomeTurnBinding) async {
        guard isHomeMode, homeTurnBinding == turn else { return }
        guard homeControlTerminal, homeAudioTerminal else { return }
        canContinueWithoutResendingHomeTurn = false
        homeReconnectConfirmsNoUnresolvedTurn = false
        homeRecovery = nil
        cancelHomeControlDeadlines()
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

    /// Release stale local recovery only after Home explicitly reports that
    /// this conversation has no active turn. The original prompt stays in the
    /// transcript, and the user chooses whether to continue without resending.
    @discardableResult
    func continueWithoutResendingHomeTurn() async -> Bool {
        guard isHomeMode,
              canContinueWithoutResendingHomeTurn,
              homeRecovery != nil,
              homeAudioHasSettled,
              connectionState.isConnected,
              !homeOperationsSuppressed,
              !isSending else {
            return false
        }

        let promptToKeep = unconfirmedTurnText
        canContinueWithoutResendingHomeTurn = false
        homeReconnectConfirmsNoUnresolvedTurn = false
        homeRecovery = nil
        homeTurnBinding = nil
        homeTurnDeliveryState = .idle
        homeTurnResult = nil
        unconfirmedTurnText = nil
        cancelHomeControlDeadlines()
        homeAudioTimeoutTask?.cancel()
        homeAudioTimeoutTask = nil
        homeAudioStartTimeoutTask?.cancel()
        homeAudioStartTimeoutTask = nil
        homeJoinTimeout = nil
        homeEventHandler = nil
        activeTurnGeneration = nil
        activeTurnText = nil
        interruptedTurnGeneration = nil
        interruptionConfirmedTurnGeneration = nil
        turnCompleted = false
        isSending = false
        activeAssistantID = nil
        activityText = nil
        transientError = nil

        let priorPrompt = messages.last(where: { $0.role == .user })?.text
        if let promptToKeep, priorPrompt != promptToKeep {
            messages.append(TranscriptMessage(role: .user, text: promptToKeep))
        }
        messages.append(TranscriptMessage(
            role: .error,
            text: "Home reports no active turn for the earlier prompt. Its reply may not have reached this app. It was not resent; you can continue."
        ))
        await persistConversation()
        return true
    }

    func respondToHomePrompt(
        _ response: HomePromptResponse
    ) async -> HomeStructuredResponseOutcome {
        guard let pending = pendingHomePrompt, let homeClient else {
            return .rejected(.home(code: .requestRejected, phase: .structuredResponse))
        }
        let outcome = await homeClient.respond(to: pending.prompt, with: response)
        if case .accepted = outcome {
            pendingHomePrompt = nil
            restartHomeControlIdle()
        }
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

    /// True only while a connected state is backed by a live transport. A
    /// cached `.connected` alone does not prove the socket survived.
    var hasLiveTransport: Bool {
        guard connectionState.isConnected else { return false }
        guard transportMode == .home else { return true }
        return homeClient != nil && homeConversationBinding != nil
    }

    func takeHomeClientForLifecycle() -> (any HomeBridgeSessionClient)? {
        canContinueWithoutResendingHomeTurn = false
        homeReconnectConfirmsNoUnresolvedTurn = false
        homeEventTask?.cancel()
        homeEventTask = nil
        cancelHomeControlDeadlines()
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
        switch connectionState {
        case .failed:
            // Keep a failure the user must see; only a live state is stale.
            break
        default:
            guard transportMode == .home else { break }
            // The caller closes this transport: never keep showing Connected.
            homeBridgeState = .disconnected(.home(code: .transportUnavailable, phase: .lifecycle))
            connectionState = .disconnected
            sessionMetadata = nil
            sessionStartedAt = nil
        }
        return activeClient
    }

    /// Persists local state for a non-active phase that keeps voice work
    /// running (IOS-HOME-07). Unlike `lifecycleWillDeactivate`, it leaves the
    /// transport, deadlines and retry ladder live; the full deactivation still
    /// runs when the retained work ends.
    func lifecycleSnapshot() async -> Bool {
        guard await persistConversation() else {
            transientError = "The local conversation could not be saved. Try again before leaving."
            return false
        }
        return true
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
        homeLifecycleGeneration &+= 1
        openHomeClaimsGeneration &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelHomeConnectRetry()
        homeEventTask?.cancel()
        homeEventTask = nil
        cancelHomeControlDeadlines()
        homeAudioStartTimeoutTask?.cancel()
        homeAudioStartTimeoutTask = nil
        homeAudioTimeoutTask?.cancel()
        homeAudioTimeoutTask = nil
        resumeHomeTurnWaiters(returning: false)
        homeAudioTerminalWaiter?.resume()
        homeAudioTerminalWaiter = nil
        homeAudioTerminal = true
        homeAudioTerminalProcessing = false
        homeTurnResult = (homeTurnBinding, false)
        await waitForHomeConnectOperation()
        await waitForOpenClaimMutation()
        return true
    }

    func setLifecycleActive(_ active: Bool) {
        if isLifecycleActive != active {
            homeLifecycleGeneration &+= 1
            openHomeClaimsGeneration &+= 1
        }
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
            // With both server terminals known, only native buffers remain.
            // Processing includes the audio-end handler awaiting native drain.
            if homeControlTerminal, homeAudioTerminal || homeAudioTerminalProcessing {
                homeAudioTerminal = true
                homeAudioTerminalProcessing = false
                await completeHomeTurnAfterAudio(for: turn)
                return true
            }
            let lifecycleGeneration = homeLifecycleGeneration
            let outcome = await homeClient.interrupt(binding: binding, turnID: turn.turnID)
            guard lifecycleGeneration == homeLifecycleGeneration else { return false }
            switch outcome {
            case .acknowledged:
                // Ack permits stopping the audio tail, but cannot manufacture
                // a control terminal for a still-running turn.
                _ = await waitForHomeTurnCompletion(turn: turn)
                guard lifecycleGeneration == homeLifecycleGeneration,
                      homeTurnResult?.turn == turn,
                      homeControlTerminal else { return false }
                guard homeTurnBinding == turn else {
                    return homeTurnBinding == nil
                }
                homeAudioTerminal = true
                homeAudioTerminalProcessing = false
                resumeHomeAudioTerminalWaiter()
                await completeHomeTurnAfterAudio(for: turn)
                return true
            case .rejected(let failure), .unavailable(let failure):
                guard homeTurnBinding == turn else { return false }
                transientError = failure.safeReason
                return false
            case .uncertain(let failure):
                guard homeTurnBinding == turn else { return false }
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
                if homeTurnBinding == turn { activeTurnGeneration = nil }
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
        homeLifecycleGeneration &+= 1
        configurationLoadGeneration &+= 1
        openHomeClaimsGeneration &+= 1
        homeOperationsSuppressed = true
        homeClaimLifecycleMutationInProgress = true
        defer { finishHomeClaimLifecycleMutation() }
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelHomeConnectRetry()
        await waitForHomeConnectOperation()
        await waitForOpenClaimMutation()

        isExpectedDisconnect = true
        await client.disconnect()
        isExpectedDisconnect = false
        let released = await closePairedHomeConversation(reason: .switchConversation)
        if !released, let claim = homeClaim {
            pendingHomeClaimsByProfile[claim.profileID] = claim
        }
        await closeHomeClient()
        homeClaim = nil
        homeClaimsPerConnect = false
        homeSession = nil
        nextHomeSessionChoice = .mostRecent
        pendingHomeSessionTitle = nil
        canStartNewHomeConversation = false
        canManageOpenHomeClaims = false
        shouldOfferManageOpenHomeClaims = false
        openHomeClaimList = nil
        openHomeClaimTitles = [:]
        openHomeClaimsError = nil

        connectionState = .disconnected
        sessionMetadata = nil
        sessionStartedAt = nil
        activityText = nil

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
        canContinueWithoutResendingHomeTurn = false
        homeReconnectConfirmsNoUnresolvedTurn = false
        homeRecovery = nil
        cancelHomeControlDeadlines()
        homeAudioTimeoutTask?.cancel()
        homeAudioTimeoutTask = nil
        homeJoinTimeout = nil
        homeConversationBinding = nil
        homeTurnBinding = nil
        homeTurnDeliveryState = .idle
        homeAudioState = .notRequested
        homeBridgeState = .unconfigured
        homeOperationsSuppressed = !isLifecycleActive
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
        DiagnosticsJournal.shared.record("store Home transport lost unexpectedly; reconnecting")
        canContinueWithoutResendingHomeTurn = false
        homeReconnectConfirmsNoUnresolvedTurn = false
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
            // The loop below reconnects the same conversation. A connect retry
            // armed earlier (for example by an uncertain submission) would wake
            // at nearly the same time and run a second recovery, whose outcome
            // could land after the loop's and leave the store reconnecting.
            cancelHomeConnectRetry()
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

            let reconnectOutcome = await homeClient.reconnect(binding: binding)
            HomeConnectionTrace.reconnect(reconnectOutcome)
            switch reconnectOutcome {
            case .ready(
                let readyBinding,
                let unresolvedTurn,
                let confirmsNoUnresolvedTurn
            ):
                guard Self.isSameConversation(readyBinding, binding) else {
                    HomeConnectionTrace.localMismatch(
                        site: "transport_loss_reconnect_ready_vs_binding fields=\(Self.bindingDifferences(readyBinding, binding))"
                    )
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
                        correlationID: homeRecovery?.turnID == nil
                            ? homeRecovery?.correlationID ?? "unresolved"
                            : homeRecovery?.correlationID
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
                homeReconnectConfirmsNoUnresolvedTurn = unresolvedTurn == nil
                    && confirmsNoUnresolvedTurn
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
                refreshHomeContinueWithoutResendingEligibility()
                startHomeEventPump(client: homeClient)
                await persistConversation()
                return
            case .unavailable(let failure):
                applyHomeConnectionFailure(failure, unavailable: true)
                if let claim = endedHomeClaim(after: failure, binding: binding),
                   isLifecycleActive, !homeOperationsSuppressed, !Task.isCancelled {
                    homeConversationBinding = nil
                    if await releaseEndedHomeClaim(claim), !Task.isCancelled {
                        await performConnect()
                    }
                }
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
                    homeRecovery: persistableHomeRecovery(homeRecovery)
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

extension PersistedHomeRecovery {
    /// Written in place of a paired client's conversation handle, which must
    /// stay out of every non-Keychain file.
    static let redactedHandle = "paired-client-claim-not-persisted"

    func replacingHandle(_ handle: String) -> PersistedHomeRecovery {
        PersistedHomeRecovery(
            schemaVersion: schemaVersion,
            profileID: profileID,
            endpoint: endpoint,
            route: route,
            householdBinding: householdBinding,
            conversationHandle: handle,
            turnID: turnID,
            correlationID: correlationID,
            submissionAttemptID: submissionAttemptID,
            resumeCursor: resumeCursor,
            deliveryState: deliveryState,
            updatedAt: updatedAt
        )
    }
}
