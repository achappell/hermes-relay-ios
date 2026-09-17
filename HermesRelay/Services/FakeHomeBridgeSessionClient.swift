import Foundation

struct AppHomeConversationClaimProvider: HomeConversationClaimProvider {
    let fakeEnabled: Bool
    let liveStore: (any HomeLiveConfigurationStore)?

    init(
        fakeEnabled: Bool = false,
        liveStore: (any HomeLiveConfigurationStore)? = nil
    ) {
        self.fakeEnabled = fakeEnabled
        self.liveStore = liveStore
    }

    func conversationClaim(for profileID: UUID) async throws -> HomeConversationClaim? {
        #if DEBUG
        if fakeEnabled {
            return HomeDemoFixtures.claim(for: profileID)
        }
        #endif
        return try await liveStore?.conversationClaim(for: profileID)
    }
}

struct AppHomeBridgeSessionClientFactory: HomeBridgeSessionClientFactory {
    let enabled: Bool
    let claimProvider: AppHomeConversationClaimProvider
    let liveFactory: (any HomeBridgeSessionClientFactory)?

    init(
        enabled: Bool,
        claimProvider: AppHomeConversationClaimProvider,
        liveFactory: (any HomeBridgeSessionClientFactory)? = nil
    ) {
        self.enabled = enabled
        self.claimProvider = claimProvider
        self.liveFactory = liveFactory
    }

    func make(
        profileID: UUID,
        mode: AppleTransportMode
    ) -> any HomeBridgeSessionClient {
        guard mode == .home else {
            return UnavailableHomeBridgeSessionClient(
                failure: .home(code: .capabilityUnavailable, phase: .lifecycle)
            )
        }
        #if DEBUG
        if enabled {
            return FakeHomeBridgeSessionClient(
                claim: HomeDemoFixtures.claim(for: profileID),
                capabilities: HomeBridgeCapabilities(
                    commands: ["open"],
                    heartbeat: true,
                    interrupt: true,
                    timing: .absent
                )
            )
        }
        #endif
        if let liveFactory {
            return liveFactory.make(profileID: profileID, mode: mode)
        }
        return UnavailableHomeBridgeSessionClient()
    }
}

enum HomeDemoFixtures {
    static func claim(for profileID: UUID) -> HomeConversationClaim {
        HomeConversationClaim(
            profileID: profileID,
            conversationHandle: "debug-conversation-\(profileID.uuidString)",
            approvedRoute: HomeApprovedRoute(
                endpoint: URL(string: "wss://home.debug.invalid/api/v1/bridge/ws")!,
                identity: HomeRouteIdentity(routeClass: .home, id: "debug-home"),
                householdBinding: "debug-household"
            )
        )
    }
}

/// Deterministic Home endpoint fixture. It models the public adapter shape
/// without opening either vanilla Hermes socket.
actor FakeHomeBridgeSessionClient: HomeBridgeSessionClient {
    let claim: HomeConversationClaim
    let configuredCapabilities: HomeBridgeCapabilities

    private let stream: AsyncThrowingStream<HomeBridgeEvent, Error>
    private let continuation: AsyncThrowingStream<HomeBridgeEvent, Error>.Continuation
    private var binding: HomeConversationBinding?
    private var turnCounter = 0
    private var promptCounter = 0
    private var closed = false
    private var pendingPrompts: [String: HomePendingStructuredPrompt] = [:]

    private(set) var openCount = 0
    private(set) var reconnectCount = 0
    private(set) var submittedTexts: [String] = []
    private(set) var interruptTurnIDs: [String] = []
    private(set) var dispatchedCommands: [String] = []
    private(set) var responseCount = 0
    private(set) var cancelPendingIDs: [HomePendingRequestID] = []
    private(set) var closeCount = 0

    var nextOpenFailure: HomeBridgeFailure?
    var nextReconnectFailure: HomeBridgeFailure?
    var nextSubmissionOutcome: HomePromptSubmissionOutcome?
    var nextInterruptOutcome: HomeInterruptOutcome?
    var nextResponseOutcome: HomeStructuredResponseOutcome?
    var nextCommandOutcome: HomeCommandOutcome?
    var nextPingOutcome: HomePingOutcome?
    var unresolvedTurn: HomeUnresolvedTurn?
    var reconnectConfirmsNoUnresolvedTurn = true

    init(
        claim: HomeConversationClaim,
        capabilities: HomeBridgeCapabilities = HomeBridgeCapabilities(
            commands: [], heartbeat: true, interrupt: true, timing: .absent
        )
    ) {
        self.claim = claim
        self.configuredCapabilities = capabilities
        let pair = AsyncThrowingStream<HomeBridgeEvent, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func open(claim requestedClaim: HomeConversationClaim) async -> HomeOpenOutcome {
        openCount += 1
        guard !closed else {
            return .disconnected(.home(code: .transportUnavailable, phase: .lifecycle))
        }
        guard requestedClaim == claim else {
            return .unavailable(.route(.identityMismatch))
        }
        if let nextOpenFailure {
            self.nextOpenFailure = nil
            return .unavailable(nextOpenFailure)
        }
        do {
            try claim.approvedRoute.validate()
        } catch {
            return .unavailable(.route(.identityMismatch))
        }
        if let binding {
            guard binding.profileID == requestedClaim.profileID,
                  binding.conversationHandle == requestedClaim.conversationHandle,
                  binding.endpoint == requestedClaim.approvedRoute.endpoint,
                  binding.route == requestedClaim.approvedRoute.identity,
                  binding.householdBinding == requestedClaim.approvedRoute.householdBinding else {
                return .unavailable(.home(code: .conversationMismatch, phase: .open))
            }
            return .ready(binding: binding, capabilities: configuredCapabilities)
        }
        let binding = HomeConversationBinding(
            profileID: claim.profileID,
            conversationHandle: claim.conversationHandle,
            endpoint: claim.approvedRoute.endpoint,
            route: claim.approvedRoute.identity,
            householdBinding: claim.approvedRoute.householdBinding,
            capabilities: configuredCapabilities
        )
        self.binding = binding
        return .ready(binding: binding, capabilities: configuredCapabilities)
    }

    func reconnect(binding requestedBinding: HomeConversationBinding) async -> HomeReconnectOutcome {
        reconnectCount += 1
        guard !closed else {
            return .disconnected(.home(code: .transportUnavailable, phase: .lifecycle))
        }
        guard requestedBinding.profileID == claim.profileID,
              requestedBinding.conversationHandle == claim.conversationHandle,
              requestedBinding.endpoint == claim.approvedRoute.endpoint,
              requestedBinding.route == claim.approvedRoute.identity,
              requestedBinding.householdBinding == claim.approvedRoute.householdBinding else {
            return .unavailable(.home(code: .conversationMismatch, phase: .reconnect))
        }
        if let binding {
            guard binding.profileID == requestedBinding.profileID,
                  binding.conversationHandle == requestedBinding.conversationHandle,
                  binding.endpoint == requestedBinding.endpoint,
                  binding.route == requestedBinding.route,
                  binding.householdBinding == requestedBinding.householdBinding else {
                return .unavailable(.home(code: .conversationMismatch, phase: .reconnect))
            }
        }
        if let nextReconnectFailure {
            self.nextReconnectFailure = nil
            return .unavailable(nextReconnectFailure)
        }
        self.binding = requestedBinding
        return .ready(
            binding: requestedBinding,
            unresolvedTurn: unresolvedTurn,
            confirmsNoUnresolvedTurn: unresolvedTurn == nil && reconnectConfirmsNoUnresolvedTurn
        )
    }

    func submitPrompt(
        _ text: String,
        binding requestedBinding: HomeConversationBinding
    ) async -> HomePromptSubmissionOutcome {
        guard let binding, binding == requestedBinding else {
            return .rejected(.home(code: .conversationMismatch, phase: .submission))
        }
        guard !closed else {
            return .uncertain(.home(code: .transportUnavailable, phase: .submission))
        }
        submittedTexts.append(text)
        if let nextSubmissionOutcome {
            self.nextSubmissionOutcome = nil
            return nextSubmissionOutcome
        }
        turnCounter += 1
        let turn = HomeTurnBinding(
            conversationHandle: binding.conversationHandle,
            turnID: "turn-\(turnCounter)",
            correlationID: "correlation-\(turnCounter)"
        )
        return .accepted(turn)
    }

    func interrupt(
        binding requestedBinding: HomeConversationBinding,
        turnID: String
    ) async -> HomeInterruptOutcome {
        guard let binding, binding == requestedBinding else {
            return .rejected(.home(code: .conversationMismatch, phase: .interrupt))
        }
        guard binding.capabilities.interrupt else {
            return .unavailable(.home(code: .capabilityUnavailable, phase: .interrupt))
        }
        interruptTurnIDs.append(turnID)
        if let nextInterruptOutcome {
            self.nextInterruptOutcome = nil
            return nextInterruptOutcome
        }
        return .acknowledged
    }

    func respond(
        to prompt: HomeStructuredPrompt,
        with response: HomePromptResponse
    ) async -> HomeStructuredResponseOutcome {
        guard let binding,
              binding.conversationHandle == prompt.conversationHandle else {
            return .rejected(.home(code: .conversationMismatch, phase: .structuredResponse))
        }
        guard let pending = pendingPrompts[prompt.correlationID],
              pending.prompt == prompt else {
            return .rejected(.home(code: .requestRejected, phase: .structuredResponse))
        }
        guard !pending.isExpired(at: Date()) else {
            pendingPrompts.removeValue(forKey: prompt.correlationID)
            return .rejected(.home(code: .requestRejected, phase: .structuredResponse))
        }
        _ = response
        responseCount += 1
        if let nextResponseOutcome {
            self.nextResponseOutcome = nil
            if case .accepted = nextResponseOutcome {
                pendingPrompts.removeValue(forKey: prompt.correlationID)
            }
            return nextResponseOutcome
        }
        pendingPrompts.removeValue(forKey: prompt.correlationID)
        return .accepted
    }

    func dispatch(_ command: HomeCommandRequest) async -> HomeCommandOutcome {
        guard let binding, binding == command.binding else {
            return .rejected(.home(code: .conversationMismatch, phase: .command))
        }
        guard binding.capabilities.commands.contains(command.name.lowercased()) else {
            return .rejected(.home(code: .capabilityUnavailable, phase: .command))
        }
        dispatchedCommands.append(command.name)
        if let nextCommandOutcome {
            self.nextCommandOutcome = nil
            return nextCommandOutcome
        }
        let result = HomeCommandResult(
            conversationHandle: binding.conversationHandle,
            turnID: nil,
            correlationID: "command-\(dispatchedCommands.count)",
            name: command.name,
            status: .completed,
            safeCode: nil
        )
        return .completed(result)
    }

    func ping(binding requestedBinding: HomeConversationBinding) async -> HomePingOutcome {
        guard let binding, binding == requestedBinding else {
            return .unavailable(.home(code: .conversationMismatch, phase: .ping))
        }
        if let nextPingOutcome {
            self.nextPingOutcome = nil
            return nextPingOutcome
        }
        return .alive
    }

    func cancelPending(requestID: HomePendingRequestID) async {
        cancelPendingIDs.append(requestID)
    }

    func events() async -> AsyncThrowingStream<HomeBridgeEvent, Error> { stream }

    func emit(_ event: HomeBridgeEvent) {
        if case .structuredPrompt(let prompt) = event {
            promptCounter += 1
            pendingPrompts[prompt.correlationID] = HomePendingStructuredPrompt(
                prompt: prompt,
                receivedAt: Date(),
                expiresAt: prompt.expiresAt
            )
        }
        continuation.yield(event)
    }

    func finishEvents() {
        continuation.finish()
    }

    func close() async {
        guard !closed else { return }
        closed = true
        closeCount += 1
        continuation.finish()
    }

    func currentBinding() -> HomeConversationBinding? { binding }

    func setNextOpenFailure(_ failure: HomeBridgeFailure?) {
        nextOpenFailure = failure
    }

    func setNextSubmissionOutcome(_ outcome: HomePromptSubmissionOutcome?) {
        nextSubmissionOutcome = outcome
    }

    func setReconnectConfirmsNoUnresolvedTurn(_ confirms: Bool) {
        reconnectConfirmsNoUnresolvedTurn = confirms
    }

    func setNextResponseOutcome(_ outcome: HomeStructuredResponseOutcome?) {
        nextResponseOutcome = outcome
    }

    func setNextCommandOutcome(_ outcome: HomeCommandOutcome?) {
        nextCommandOutcome = outcome
    }
}
