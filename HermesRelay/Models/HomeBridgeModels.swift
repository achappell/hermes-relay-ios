import Foundation

enum HomeRouteClass: String, Codable, Sendable {
    case home
    case tailscale
    case `public`
}

struct HomeRouteIdentity: Codable, Equatable, Sendable {
    let routeClass: HomeRouteClass
    let id: String

    init(routeClass: HomeRouteClass, id: String) {
        self.routeClass = routeClass
        self.id = id
    }

    var isValid: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum HomeRouteValidationError: Error, Equatable, Sendable {
    case unsupportedScheme
    case invalidPath
    case endpointContainsCredentials
    case invalidIdentity
    case emptyHouseholdBinding
}

struct HomeApprovedRoute: Codable, Equatable, Sendable {
    let endpoint: URL
    let identity: HomeRouteIdentity
    let householdBinding: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case endpoint, identity, householdBinding
    }

    init(endpoint: URL, identity: HomeRouteIdentity, householdBinding: String) {
        self.endpoint = endpoint
        self.identity = identity
        self.householdBinding = householdBinding
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try HomeCoding.requireExactKeys(decoder, allowed: CodingKeys.allCases)
        endpoint = try values.decode(URL.self, forKey: .endpoint)
        identity = try values.decode(HomeRouteIdentity.self, forKey: .identity)
        householdBinding = try values.decode(String.self, forKey: .householdBinding)
        try validate()
    }

    func validate() throws {
        guard endpoint.scheme?.lowercased() == "wss" else {
            throw HomeRouteValidationError.unsupportedScheme
        }
        guard endpoint.path == "/api/v1/bridge/ws" else {
            throw HomeRouteValidationError.invalidPath
        }
        guard endpoint.host != nil,
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil else {
            throw HomeRouteValidationError.endpointContainsCredentials
        }
        guard identity.isValid else {
            throw HomeRouteValidationError.invalidIdentity
        }
        guard !householdBinding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HomeRouteValidationError.emptyHouseholdBinding
        }
    }
}

/// The wire key is `class`; the local property deliberately remains
/// `routeClass` so the endpoint shape cannot leak into local naming.
struct HomeWireRoute: Codable, Equatable, Sendable {
    let routeClass: HomeRouteClass
    let id: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case routeClass = "class"
        case id
    }

    init(routeClass: HomeRouteClass, id: String) {
        self.routeClass = routeClass
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try HomeCoding.requireExactKeys(decoder, allowed: CodingKeys.allCases)
        routeClass = try container.decode(HomeRouteClass.self, forKey: .routeClass)
        id = try container.decode(String.self, forKey: .id)
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HomeWireDecodingError.invalidShape
        }
    }
}

enum HomeBridgeReadyStatus: String, Codable, Sendable {
    case ready
    case unavailable
}

struct HomeWireCapabilities: Codable, Equatable, Sendable {
    let commands: [String]
    let heartbeat: Bool
    let timing: HomeTimingCapability
    let interrupt: Bool?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case commands, heartbeat, timing, interrupt
    }

    init(
        commands: [String],
        heartbeat: Bool,
        timing: HomeTimingCapability,
        interrupt: Bool? = nil
    ) {
        self.commands = commands
        self.heartbeat = heartbeat
        self.timing = timing
        self.interrupt = interrupt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try HomeCoding.requireExactKeys(decoder, allowed: CodingKeys.allCases)
        commands = try container.decode([String].self, forKey: .commands)
        heartbeat = try container.decode(Bool.self, forKey: .heartbeat)
        timing = try container.decode(HomeTimingCapability.self, forKey: .timing)
        interrupt = try container.decodeIfPresent(Bool.self, forKey: .interrupt)
    }
}

struct HomeReadyWireResult: Codable, Equatable, Sendable {
    let schema: Int
    let status: HomeBridgeReadyStatus
    let conversationHandle: String
    let route: HomeWireRoute?
    let capabilities: HomeWireCapabilities?
    let reason: HomeWireReason?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, status
        case conversationHandle = "conversation_handle"
        case route, capabilities, reason
    }

    init(
        schema: Int,
        status: HomeBridgeReadyStatus,
        conversationHandle: String,
        route: HomeWireRoute?,
        capabilities: HomeWireCapabilities?,
        reason: HomeWireReason?
    ) {
        self.schema = schema
        self.status = status
        self.conversationHandle = conversationHandle
        self.route = route
        self.capabilities = capabilities
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try HomeCoding.requireExactKeys(decoder, allowed: CodingKeys.allCases)
        schema = try container.decode(Int.self, forKey: .schema)
        status = try container.decode(HomeBridgeReadyStatus.self, forKey: .status)
        conversationHandle = try container.decode(String.self, forKey: .conversationHandle)
        route = try container.decodeIfPresent(HomeWireRoute.self, forKey: .route)
        capabilities = try container.decodeIfPresent(HomeWireCapabilities.self, forKey: .capabilities)
        reason = try container.decodeIfPresent(HomeWireReason.self, forKey: .reason)
    }
}

enum HomeFailureCode: String, Codable, Sendable {
    case invalidRequest = "invalid_request"
    case authorizationUnavailable = "authorization_unavailable"
    case unauthorized
    case staleConversation = "stale_conversation"
    case conversationMismatch = "conversation_mismatch"
    case requestRejected = "request_rejected"
    case transportUnavailable = "transport_unavailable"
    case transportTimeout = "transport_timeout"
    case protocolError = "protocol_error"
    case capabilityUnavailable = "capability_unavailable"
    case hermesUnavailable = "hermes_unavailable"
}

enum HomeWireReason: String, Codable, Sendable {
    case reconnectRequired = "reconnect_required"
    case invalidRequest = "invalid_request"
    case authorizationUnavailable = "authorization_unavailable"
    case unauthorized
    case staleConversation = "stale_conversation"
    case conversationMismatch = "conversation_mismatch"
    case requestRejected = "request_rejected"
    case transportUnavailable = "transport_unavailable"
    case transportTimeout = "transport_timeout"
    case protocolError = "protocol_error"
    case capabilityUnavailable = "capability_unavailable"
    case hermesUnavailable = "hermes_unavailable"
    case routeUnavailable = "route_unavailable"
    case routeUnauthorized = "route_unauthorized"
    case routeIdentityMismatch = "route_identity_mismatch"
    case routeTimeout = "route_timeout"
}

enum HomeRouteAttemptFailure: String, Codable, Sendable {
    case unavailable
    case unauthorized
    case identityMismatch
    case timeout
}

enum HomeFailurePhase: String, Codable, Sendable {
    case route, authorization, open, reconnect, submission, interrupt
    case structuredResponse, command, ping, audio, lifecycle
}

enum HomeFailureClassification: String, Codable, Sendable {
    case known
    case uncertain
    case unavailable
}

enum HomeBridgeFailure: Equatable, Sendable {
    case home(code: HomeFailureCode, phase: HomeFailurePhase)
    case route(HomeRouteAttemptFailure)
    case reconnectRequired
    case publicAdapterUnavailable

    var classification: HomeFailureClassification {
        switch self {
        case .home(let code, _):
            switch code {
            case .transportUnavailable, .transportTimeout:
                return .uncertain
            default:
                return .known
            }
        case .route, .reconnectRequired, .publicAdapterUnavailable:
            return .unavailable
        }
    }

    var safeCode: HomeFailureCode? {
        guard case .home(let code, _) = self else { return nil }
        return code
    }

    var phase: HomeFailurePhase? {
        guard case .home(_, let phase) = self else { return nil }
        return phase
    }

    var safeReason: String {
        switch self {
        case .home(let code, _):
            return code.rawValue
        case .route(let reason):
            switch reason {
            case .unavailable: return HomeWireReason.routeUnavailable.rawValue
            case .unauthorized: return HomeWireReason.routeUnauthorized.rawValue
            case .identityMismatch: return HomeWireReason.routeIdentityMismatch.rawValue
            case .timeout: return HomeWireReason.routeTimeout.rawValue
            }
        case .reconnectRequired:
            return HomeWireReason.reconnectRequired.rawValue
        case .publicAdapterUnavailable:
            return "public_adapter_unavailable"
        }
    }
}

struct HomeConversationBinding: Equatable, Sendable {
    let profileID: UUID
    let conversationHandle: String
    let endpoint: URL
    let route: HomeRouteIdentity
    let householdBinding: String
    let capabilities: HomeBridgeCapabilities
}

struct HomeConversationClaim: Equatable, Sendable {
    let profileID: UUID
    let conversationHandle: String
    let approvedRoute: HomeApprovedRoute
}

struct HomeTurnBinding: Equatable, Sendable {
    let conversationHandle: String
    let turnID: String
    let correlationID: String
}

struct HomeBridgeCapabilities: Equatable, Sendable {
    let commands: Set<String>
    let heartbeat: Bool
    let interrupt: Bool
    let timing: HomeTimingCapability

    init(
        commands: Set<String> = [],
        heartbeat: Bool = false,
        interrupt: Bool = false,
        timing: HomeTimingCapability = .absent
    ) {
        self.commands = commands
        self.heartbeat = heartbeat
        self.interrupt = interrupt
        self.timing = timing
    }

    init(_ wire: HomeWireCapabilities) {
        self.init(
            commands: Set(wire.commands.map { $0.lowercased() }),
            heartbeat: wire.heartbeat,
            interrupt: wire.interrupt ?? false,
            timing: wire.timing
        )
    }
}

enum HomeTimingCapability: String, Codable, Sendable {
    case absent
}

enum HomeByteOrder: String, Codable, Sendable {
    case little
}

struct HomeAudioFormat: Codable, Equatable, Sendable {
    let sampleRate: Int
    let channels: Int
    let sampleWidth: Int
    let byteOrder: HomeByteOrder

    init(
        sampleRate: Int,
        channels: Int,
        sampleWidth: Int,
        byteOrder: HomeByteOrder = .little
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.sampleWidth = sampleWidth
        self.byteOrder = byteOrder
    }

    var isValidSignedPCM: Bool {
        sampleRate > 0 && channels == 1 && sampleWidth == 2 && byteOrder == .little
    }
}

enum HomeBridgeState: Equatable, Sendable {
    case unconfigured
    case connecting
    case ready(HomeConversationBinding)
    case disconnected(HomeBridgeFailure)
    case unavailable(HomeBridgeFailure)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var safeReason: String? {
        switch self {
        case .unavailable(let failure), .disconnected(let failure):
            return failure.safeReason
        default:
            return nil
        }
    }
}

enum HomeTurnDeliveryState: Equatable, Sendable {
    case idle
    case awaitingAcceptance(attemptID: UUID)
    case accepted(HomeTurnBinding)
    case completed(HomeTurnBinding)
    case interrupted(HomeTurnBinding)
    case failedKnown(HomeBridgeFailure)
    case uncertain(HomeTurnBinding?)

    var binding: HomeTurnBinding? {
        switch self {
        case .accepted(let binding), .completed(let binding), .interrupted(let binding):
            return binding
        case .uncertain(let binding):
            return binding
        default:
            return nil
        }
    }
}

enum HomeAudioState: Equatable, Sendable {
    case notRequested
    case waitingForStart(generation: UInt64)
    case streaming(format: HomeAudioFormat, generation: UInt64)
    case ended(generation: UInt64)
    case fallback(generation: UInt64)
    case unavailable(generation: UInt64)
    case invalid(generation: UInt64)
}

extension HomeBridgeState {
    var displayLabel: String {
        switch self {
        case .unconfigured: return "Not configured"
        case .connecting: return "Connecting"
        case .ready: return "Ready"
        case .disconnected: return "Disconnected"
        case .unavailable: return "Unavailable"
        }
    }

    var displayReason: String? {
        switch self {
        case .disconnected(let failure), .unavailable(let failure):
            return failure.safeReason
        case .unconfigured, .connecting, .ready:
            return nil
        }
    }
}

extension HomeRouteState {
    var displayLabel: String {
        switch status {
        case .unattempted: return "Not attempted"
        case .attempting: return "Attempting"
        case .reachable: return "Approved route reachable"
        case .failed: return "Route unavailable"
        }
    }
}

extension HomeTurnDeliveryState {
    var displayLabel: String {
        switch self {
        case .idle: return "Idle"
        case .awaitingAcceptance: return "Awaiting acceptance"
        case .accepted: return "Accepted"
        case .completed: return "Completed"
        case .interrupted: return "Interrupted"
        case .failedKnown: return "Known failure"
        case .uncertain: return "Uncertain — action required"
        }
    }
}

extension HomeAudioState {
    var displayLabel: String {
        switch self {
        case .notRequested: return "Not requested"
        case .waitingForStart: return "Waiting for audio"
        case .streaming: return "Streaming PCM"
        case .ended: return "Ended"
        case .fallback: return "Fallback"
        case .unavailable: return "Unavailable"
        case .invalid: return "Invalid audio rejected"
        }
    }
}

extension HomeStructuredPromptKind {
    var displayLabel: String {
        switch self {
        case .approval: return "Approval"
        case .clarification: return "Clarification"
        case .secret: return "Secret"
        case .sudo: return "Sudo"
        }
    }
}

protocol HomeMonotonicClock: Sendable {
    func now() -> ContinuousClock.Instant
    func sleep(until: ContinuousClock.Instant) async throws
}

struct ContinuousHomeMonotonicClock: HomeMonotonicClock {
    private let clock = ContinuousClock()

    func now() -> ContinuousClock.Instant { clock.now }

    func sleep(until instant: ContinuousClock.Instant) async throws {
        try await clock.sleep(until: instant)
    }
}

struct HomePendingRequestID: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    init() { self.init(rawValue: UUID().uuidString) }
}

struct HomeOperationDeadlines: Equatable, Sendable {
    let open: Duration
    let reconnectAttempt: Duration
    let reconnectOverall: Duration
    let promptAcceptance: Duration
    let structuredResponse: Duration
    let command: Duration
    let interruptAcknowledgement: Duration
    let ping: Duration

    static let `default` = HomeOperationDeadlines(
        open: .seconds(10),
        reconnectAttempt: .seconds(10),
        reconnectOverall: .seconds(60),
        promptAcceptance: .seconds(10),
        structuredResponse: .seconds(10),
        command: .seconds(10),
        interruptAcknowledgement: .seconds(2),
        ping: .seconds(5)
    )
}

enum HomeDeadlineError: Error, Equatable, Sendable {
    case timedOut(HomePendingRequestID)
}

func withHomeDeadline<T: Sendable>(
    requestID: HomePendingRequestID,
    timeout: Duration,
    clock: any HomeMonotonicClock,
    cancelPending: @escaping @Sendable (HomePendingRequestID) async -> Void,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await clock.sleep(until: clock.now().advanced(by: timeout))
                try Task.checkCancellation()
                throw HomeDeadlineError.timedOut(requestID)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    } catch {
        if error is HomeDeadlineError || error is CancellationError {
            await cancelPending(requestID)
        }
        throw error
    }
}

enum HomePromptSubmissionOutcome: Equatable, Sendable {
    case accepted(HomeTurnBinding)
    case rejected(HomeBridgeFailure)
    case uncertain(HomeBridgeFailure)
}

protocol HomeApprovedRouteProvider: Sendable {
    func approvedRoute(for profileID: UUID) async throws -> HomeApprovedRoute?
}

protocol HomeBridgeSessionClient: Sendable {
    func open(claim: HomeConversationClaim) async -> HomeOpenOutcome
    func reconnect(binding: HomeConversationBinding) async -> HomeReconnectOutcome
    func submitPrompt(
        _ text: String,
        binding: HomeConversationBinding
    ) async -> HomePromptSubmissionOutcome
    func interrupt(
        binding: HomeConversationBinding,
        turnID: String
    ) async -> HomeInterruptOutcome
    func respond(
        to prompt: HomeStructuredPrompt,
        with response: HomePromptResponse
    ) async -> HomeStructuredResponseOutcome
    func dispatch(_ command: HomeCommandRequest) async -> HomeCommandOutcome
    func ping(binding: HomeConversationBinding) async -> HomePingOutcome
    func cancelPending(requestID: HomePendingRequestID) async
    func events() async -> AsyncThrowingStream<HomeBridgeEvent, Error>
    func close() async
}

enum HomeOpenOutcome: Equatable, Sendable {
    case ready(binding: HomeConversationBinding, capabilities: HomeBridgeCapabilities)
    case unavailable(HomeBridgeFailure)
    case disconnected(HomeBridgeFailure)
}

enum HomeReconnectOutcome: Equatable, Sendable {
    case ready(binding: HomeConversationBinding, unresolvedTurn: HomeUnresolvedTurn?)
    case unavailable(HomeBridgeFailure)
    case disconnected(HomeBridgeFailure)
}

struct HomeUnresolvedTurn: Equatable, Sendable {
    let turnID: String
    let resumeCursor: String?
}

enum HomeInterruptOutcome: Equatable, Sendable {
    case acknowledged
    case rejected(HomeBridgeFailure)
    case unavailable(HomeBridgeFailure)
    case uncertain(HomeBridgeFailure)
}

enum HomeStructuredResponseOutcome: Equatable, Sendable {
    case accepted
    case rejected(HomeBridgeFailure)
    case uncertain(HomeBridgeFailure)
}

enum HomeStructuredPromptKind: String, Codable, Sendable {
    case approval, clarification, secret, sudo
}

struct HomeEventScope: Equatable, Sendable {
    let conversationHandle: String
    let turnID: String?
    let correlationID: String?
}

struct HomeStructuredPrompt: Equatable, Sendable {
    let kind: HomeStructuredPromptKind
    let conversationHandle: String
    let turnID: String
    let correlationID: String
    let options: [String]
    let expiresAt: Date?
    let sensitive: Bool

    var eventType: String {
        switch kind {
        case .approval: return "approval.request"
        case .clarification: return "clarify.request"
        case .secret: return "secret.request"
        case .sudo: return "sudo.request"
        }
    }
}

enum HomePromptResponse: Equatable, Sendable {
    case approval(choice: String, all: Bool?)
    case clarification(answer: String)
    case secret(value: String)
    case sudo(password: String)
}

struct HomePendingStructuredPrompt: Equatable, Sendable {
    let prompt: HomeStructuredPrompt
    let receivedAt: Date
    let expiresAt: Date?

    func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return date >= expiresAt
    }
}

enum HomeStandardEventType: String, Codable, Sendable {
    case messageStart = "message.start"
    case messageDelta = "message.delta"
    case textDelta = "text_delta"
    case text = "text"
    case textFinal = "text_final"
    case messageComplete = "message.complete"
    case thinking
    case reasoning
    case status
    case turnComplete = "turn_complete"
    case turnInterrupted = "turn_interrupted"
    case audioAbort = "audio_abort"
    case error
}

enum HomeStandardEventKind: String, Codable, Sendable {
    case assistant, thinking, status, terminal
}

enum HomeActivityKind: String, Codable, Sendable {
    case working, thinking, speaking, listening, waiting, idle, stopped
}

struct HomeSafeError: Codable, Equatable, Sendable {
    let code: HomeFailureCode
    let phase: HomeFailurePhase

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code, phase
    }

    init(code: HomeFailureCode, phase: HomeFailurePhase) {
        self.code = code
        self.phase = phase
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try HomeCoding.requireExactKeys(decoder, allowed: CodingKeys.allCases)
        code = try container.decode(HomeFailureCode.self, forKey: .code)
        phase = try container.decode(HomeFailurePhase.self, forKey: .phase)
    }
}

enum HomeStandardEventPayload: Equatable, Sendable {
    case start(kind: HomeStandardEventKind?)
    case delta(
        rendered: String?,
        text: String?,
        replace: Bool,
        kind: HomeStandardEventKind?
    )
    case final(
        rendered: String?,
        text: String?,
        status: String?,
        reasoning: String?,
        failureReason: HomeFailureCode?
    )
    case activity(
        text: String?,
        status: String?,
        reasoning: String?,
        kind: HomeStandardEventKind?
    )
    case terminal(kind: HomeStandardEventKind?)
    case error(HomeSafeError)
}

struct HomeStandardEvent: Equatable, Sendable {
    let type: HomeStandardEventType
    let scope: HomeEventScope
    let payload: HomeStandardEventPayload
}

enum HomeAudioTerminal: String, Sendable {
    case end, fallback, unavailable
}

enum HomeBridgeEvent: Equatable, Sendable {
    case standard(HomeStandardEvent)
    case audioStart(HomeEventScope, HomeAudioFormat)
    case audioTerminal(HomeEventScope, HomeAudioTerminal)
    case binaryPCM(HomeEventScope, Data)
    case structuredPrompt(HomeStructuredPrompt)
    case command(HomeCommandEvent)
    case activity(HomeEventScope?, HomeActivityKind)
}

enum HomePCMError: Error, Equatable, Sendable {
    case invalidTerminalAlignment
}

struct HomePCMAccumulator: Sendable {
    private var pending = Data()

    init() {}

    mutating func append(transportChunk: Data) throws -> Data {
        pending.append(transportChunk)
        let completeByteCount = pending.count - pending.count % 2
        guard completeByteCount > 0 else { return Data() }
        let complete = Data(pending.prefix(completeByteCount))
        pending.removeFirst(completeByteCount)
        return complete
    }

    mutating func finish() throws {
        guard pending.isEmpty else { throw HomePCMError.invalidTerminalAlignment }
    }
}

enum HomeTurnJoinTimeout: Equatable, Sendable {
    case audioStartMissing
    case controlTerminalMissing
    case audioTerminalMissing
    case playbackDrainTimedOut
}

struct HomeTurnAudioDeadlines: Equatable, Sendable {
    let audioStart: Duration
    let controlTerminal: Duration
    let audioTerminal: Duration
    let playbackDrain: Duration

    static let `default` = HomeTurnAudioDeadlines(
        audioStart: .seconds(5),
        controlTerminal: .seconds(30),
        audioTerminal: .seconds(30),
        playbackDrain: .seconds(5)
    )
}

enum HomeCredentialKeychain {
    static let service = "com.achappell.HermesRelayIOS.home-device"

    static func account(for profileID: UUID) -> String {
        "device-credential.\(profileID.uuidString)"
    }
}

enum HomeCredentialReferenceError: Error, Equatable, Sendable {
    case wrongServiceOrAccount
    case invalidLifecycleDates
}

struct HomeCredentialReference: Codable, Equatable, Sendable {
    let service: String
    let account: String
    let issuedAt: Date
    let expiresAt: Date
    let renewAfter: Date
    let overlapUntil: Date?

    func validate(for profileID: UUID) throws {
        guard service == HomeCredentialKeychain.service,
              account == HomeCredentialKeychain.account(for: profileID) else {
            throw HomeCredentialReferenceError.wrongServiceOrAccount
        }

        let ninetyDays: TimeInterval = 90 * 24 * 60 * 60
        let fourteenDays: TimeInterval = 14 * 24 * 60 * 60
        let tenMinutes: TimeInterval = 10 * 60
        guard expiresAt.timeIntervalSince(issuedAt) == ninetyDays,
              renewAfter == expiresAt.addingTimeInterval(-fourteenDays),
              expiresAt >= issuedAt,
              overlapUntil == nil || overlapUntil! <= expiresAt.addingTimeInterval(tenMinutes) else {
            throw HomeCredentialReferenceError.invalidLifecycleDates
        }
    }

    func isRenewalEligible(at date: Date) -> Bool {
        date >= renewAfter && date < expiresAt
    }

    func isExpired(at date: Date) -> Bool {
        date >= expiresAt
    }
}

enum HomeCredentialState: String, Codable, Sendable {
    case active, expired, revoked, replaced
}

struct HomeCredentialRecord: Codable, Equatable, Sendable {
    let profileID: UUID
    let reference: HomeCredentialReference
    let state: HomeCredentialState

    var isUsableForNewWork: Bool {
        state == .active
    }
}

protocol HomePairingCredentialHandoff: Sendable {
    func preIssuedReference(for profileID: UUID) async throws -> HomeCredentialReference
}

protocol HomeCredentialStore: Sendable {
    func stage(preIssued: HomeCredentialReference, for profileID: UUID) async throws
    func verifiedReadBack(for profileID: UUID) async throws -> HomeCredentialRecord
    func withPrivateDeviceCredential(
        for profileID: UUID,
        _ body: @Sendable (Data) async throws -> Void
    ) async throws
    func commitHomeSelection(for profileID: UUID) async throws
    func rollbackToLegacyAtIdle(for profileID: UUID) async throws
}

enum HomeMigrationPhase: String, Codable, Sendable {
    case notStarted
    case staged
    case readBackVerified
    case fakeReadyVerified
    case homeSelected
    case rollbackPending
    case legacySelected
}

struct HomeMigrationJournal: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let profileID: UUID
    var phase: HomeMigrationPhase
    var selectedMode: AppleTransportMode
    var credential: HomeCredentialReference?
    var legacyCredentialRetained: Bool
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, profileID, phase, selectedMode, credential
        case legacyCredentialRetained, updatedAt
    }

    init(
        schemaVersion: Int,
        profileID: UUID,
        phase: HomeMigrationPhase,
        selectedMode: AppleTransportMode,
        credential: HomeCredentialReference?,
        legacyCredentialRetained: Bool,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.phase = phase
        self.selectedMode = selectedMode
        self.credential = credential
        self.legacyCredentialRetained = legacyCredentialRetained
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        let profileID = try values.decode(UUID.self, forKey: .profileID)
        let rawPhase = try values.decodeIfPresent(String.self, forKey: .phase)
        let rawMode = try values.decodeIfPresent(String.self, forKey: .selectedMode)
        let phase = schemaVersion == 1
            ? rawPhase.flatMap(HomeMigrationPhase.init(rawValue:)) ?? .rollbackPending
            : .rollbackPending
        let selectedMode = rawMode.flatMap(AppleTransportMode.init(rawValue:)) ?? .legacy
        self.init(
            schemaVersion: schemaVersion,
            profileID: profileID,
            phase: phase,
            selectedMode: phase == .homeSelected ? selectedMode : .legacy,
            credential: try values.decodeIfPresent(HomeCredentialReference.self, forKey: .credential),
            legacyCredentialRetained: try values.decodeIfPresent(Bool.self, forKey: .legacyCredentialRetained) ?? true,
            updatedAt: try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        )
    }
}

enum PersistedHomeDeliveryState: String, Codable, Sendable {
    case awaitingAcceptance
    case accepted
    case uncertain
}

struct PersistedHomeRecovery: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let profileID: UUID
    let endpoint: URL
    let route: HomeRouteIdentity
    let householdBinding: String
    let conversationHandle: String
    let turnID: String?
    let correlationID: String?
    let submissionAttemptID: UUID?
    let resumeCursor: String?
    let deliveryState: PersistedHomeDeliveryState
    let updatedAt: Date

    init(
        schemaVersion: Int = 1,
        profileID: UUID,
        endpoint: URL,
        route: HomeRouteIdentity,
        householdBinding: String,
        conversationHandle: String,
        turnID: String? = nil,
        correlationID: String? = nil,
        submissionAttemptID: UUID? = nil,
        resumeCursor: String? = nil,
        deliveryState: PersistedHomeDeliveryState,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.endpoint = endpoint
        self.route = route
        self.householdBinding = householdBinding
        self.conversationHandle = conversationHandle
        self.turnID = turnID
        self.correlationID = correlationID
        self.submissionAttemptID = submissionAttemptID
        self.resumeCursor = resumeCursor
        self.deliveryState = deliveryState
        self.updatedAt = updatedAt
    }
}

enum AppleTransportMode: String, Codable, Sendable {
    case home
    case legacy
}

struct HomeCommandRequest: Equatable, Sendable {
    let binding: HomeConversationBinding
    let name: String
    let argument: String?
}

enum HomeCommandStatus: String, Codable, Sendable {
    case accepted, completed, rejected, unavailable
}

struct HomeCommandEvent: Equatable, Sendable {
    let conversationHandle: String
    let turnID: String?
    let correlationID: String
    let name: String
    let status: HomeCommandStatus
    let safeCode: HomeFailureCode?
}

enum HomeCommandOutcome: Equatable, Sendable {
    case completed(HomeCommandResult)
    case rejected(HomeBridgeFailure)
    case uncertain(HomeBridgeFailure)
}

struct HomeCommandResult: Equatable, Sendable {
    let conversationHandle: String
    let turnID: String?
    let correlationID: String
    let name: String
    let status: HomeCommandStatus
    let safeCode: HomeFailureCode?
}

enum HomePingOutcome: Equatable, Sendable {
    case alive
    case unavailable(HomeBridgeFailure)
}

struct HomeBridgeClientDependencies: Sendable {
    let routeProvider: any HomeApprovedRouteProvider
    let credentialStore: any HomeCredentialStore
    let clock: any HomeMonotonicClock
    let socketFactory: any WebSocketConnectionFactory
    let publicAdapterEnabled: Bool

    init(
        routeProvider: any HomeApprovedRouteProvider,
        credentialStore: any HomeCredentialStore,
        clock: any HomeMonotonicClock = ContinuousHomeMonotonicClock(),
        socketFactory: any WebSocketConnectionFactory = URLSessionWebSocketConnectionFactory(),
        publicAdapterEnabled: Bool = false
    ) {
        self.routeProvider = routeProvider
        self.credentialStore = credentialStore
        self.clock = clock
        self.socketFactory = socketFactory
        self.publicAdapterEnabled = publicAdapterEnabled
    }
}

protocol HomeBridgeSessionClientFactory: Sendable {
    func make(
        profileID: UUID,
        mode: AppleTransportMode
    ) -> any HomeBridgeSessionClient
}

struct HomeRouteState: Equatable, Sendable {
    enum Status: String, Sendable {
        case unattempted, attempting, reachable, failed
    }

    let status: Status
    let identity: HomeRouteIdentity?
    let failure: HomeRouteAttemptFailure?
}

enum HomeWireDecodingError: Error, Equatable, Sendable {
    case invalidShape
    case unsupportedSchema
    case unsupportedMethod
    case requestIDMismatch
    case conversationMismatch
    case turnMismatch
    case correlationMismatch
    case unknownField
    case invalidAudioFrame
}

/// A small Codable JSON value is used only by the wire envelope. Domain state
/// never stores it; operation-specific encoders keep secrets out of it.
indirect enum HomeJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: HomeJSONValue])
    case array([HomeJSONValue])
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), container.decodeNil() {
            self = .null
        } else if let value = try? decoder.singleValueContainer().decode(String.self) {
            self = .string(value)
        } else if let value = try? decoder.singleValueContainer().decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? decoder.singleValueContainer().decode(Double.self) {
            self = .number(value)
        } else if var container = try? decoder.unkeyedContainer() {
            var values: [HomeJSONValue] = []
            while !container.isAtEnd { values.append(try container.decode(HomeJSONValue.self)) }
            self = .array(values)
        } else {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            var values: [String: HomeJSONValue] = [:]
            for key in container.allKeys {
                values[key.stringValue] = try container.decode(HomeJSONValue.self, forKey: key)
            }
            self = .object(values)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value): try value.encode(to: encoder)
        case .number(let value): try value.encode(to: encoder)
        case .bool(let value): try value.encode(to: encoder)
        case .object(let value): try value.encode(to: encoder)
        case .array(let value): try value.encode(to: encoder)
        case .null: var container = encoder.singleValueContainer(); try container.encodeNil()
        }
    }
}

struct HomeJSONRPCRequest: Codable, Equatable, Sendable {
    let jsonrpc: String
    let schema: Int
    let id: String
    let method: String
    let params: [String: HomeJSONValue]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case jsonrpc, schema, id, method, params
    }

    init(id: String, method: String, params: [String: HomeJSONValue]) {
        self.jsonrpc = "2.0"
        self.schema = 1
        self.id = id
        self.method = method
        self.params = params
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try HomeCoding.requireExactKeys(decoder, allowed: CodingKeys.allCases)
        guard try values.decode(String.self, forKey: .jsonrpc) == "2.0",
              try values.decode(Int.self, forKey: .schema) == 1 else {
            throw HomeWireDecodingError.unsupportedSchema
        }
        jsonrpc = "2.0"
        schema = 1
        id = try values.decode(String.self, forKey: .id)
        method = try values.decode(String.self, forKey: .method)
        params = try values.decode([String: HomeJSONValue].self, forKey: .params)
        guard !id.isEmpty, !method.isEmpty else { throw HomeWireDecodingError.invalidShape }
    }
}

struct HomeJSONRPCResponse: Codable, Equatable, Sendable {
    let jsonrpc: String
    let schema: Int
    let id: String
    let result: [String: HomeJSONValue]?
    let error: HomeJSONRPCError?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case jsonrpc, schema, id, result, error
    }

    init(
        id: String,
        result: [String: HomeJSONValue]? = nil,
        error: HomeJSONRPCError? = nil
    ) {
        self.jsonrpc = "2.0"
        self.schema = 1
        self.id = id
        self.result = result
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try HomeCoding.requireExactKeys(decoder, allowed: CodingKeys.allCases)
        guard try values.decode(String.self, forKey: .jsonrpc) == "2.0",
              try values.decode(Int.self, forKey: .schema) == 1 else {
            throw HomeWireDecodingError.unsupportedSchema
        }
        jsonrpc = "2.0"
        schema = 1
        id = try values.decode(String.self, forKey: .id)
        result = try values.decodeIfPresent([String: HomeJSONValue].self, forKey: .result)
        error = try values.decodeIfPresent(HomeJSONRPCError.self, forKey: .error)
        guard !id.isEmpty, (result != nil) != (error != nil) else {
            throw HomeWireDecodingError.invalidShape
        }
    }
}

struct HomeJSONRPCError: Codable, Equatable, Sendable {
    let code: String
    let data: [String: HomeJSONValue]?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code, data
    }

    init(code: String, data: [String: HomeJSONValue]? = nil) {
        self.code = code
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try HomeCoding.requireExactKeys(decoder, allowed: CodingKeys.allCases)
        code = try values.decode(String.self, forKey: .code)
        data = try values.decodeIfPresent([String: HomeJSONValue].self, forKey: .data)
        guard !code.isEmpty else { throw HomeWireDecodingError.invalidShape }
    }
}

private enum DynamicCodingKey: CodingKey {
    case string(String)

    init?(stringValue: String) { self = .string(stringValue) }
    var stringValue: String {
        if case .string(let value) = self { return value }
        return ""
    }
    init?(intValue: Int) { return nil }
    var intValue: Int? { nil }
}

private enum HomeCoding {
    static func requireExactKeys<K: CodingKey>(
        _ decoder: Decoder,
        allowed: [K]
    ) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let allowedNames = Set(allowed.map(\.stringValue))
        guard container.allKeys.allSatisfy({ allowedNames.contains($0.stringValue) }) else {
            throw HomeWireDecodingError.unknownField
        }
    }

    static func requireExactKeys<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        allowed: [K]
    ) throws {
        let allowedNames = Set(allowed.map(\.stringValue))
        guard container.allKeys.allSatisfy({ allowedNames.contains($0.stringValue) }) else {
            throw HomeWireDecodingError.unknownField
        }
    }
}
