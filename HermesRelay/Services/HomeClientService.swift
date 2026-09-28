import Foundation

/// HTTP routes a paired personal client uses (HOME-NW-17). Every call that
/// needs the Device credential receives it as bytes from inside the Keychain
/// accessor; nothing here stores, logs, or returns it.
protocol HomeClientService: Sendable {
    func submitEnrollment(
        home: HomeClientBaseURL,
        _ submission: HomeEnrollmentSubmission
    ) async throws -> HomeEnrollmentPendingRequest

    func consumeEnrollment(
        home: HomeClientBaseURL,
        requestID: String,
        enrollmentCode: String
    ) async throws -> HomeCredentialMaterial

    func renewCredential(
        home: HomeClientBaseURL,
        deviceID: String,
        credential: Data,
        requestID: String,
        generation: Int
    ) async throws -> HomeCredentialMaterial

    func deviceConfiguration(
        home: HomeClientBaseURL,
        deviceID: String,
        credential: Data
    ) async throws -> HomeClientDeviceConfiguration

    func claimConversation(
        home: HomeClientBaseURL,
        credential: Data,
        _ request: HomeClientClaimRequest
    ) async throws -> HomeClientClaimGrant

    /// The grant's Profile sessions, newest first (`POST /api/v1/client-sessions/list`).
    func listSessions(
        home: HomeClientBaseURL,
        credential: Data,
        _ request: HomeClientSessionListRequest
    ) async throws -> [HomeClientSessionSummary]

    /// The session this device's own claim uses (`POST /api/v1/client-claims/session`).
    func claimSession(
        home: HomeClientBaseURL,
        credential: Data,
        _ request: HomeClientClaimSessionRequest
    ) async throws -> HomeClientClaimSessionLookup

    /// Grants waiting for this device's owner decision (`GET /api/v1/profile-grants/pending`).
    func pendingProfileGrants(
        home: HomeClientBaseURL,
        credential: Data
    ) async throws -> [HomeProfileGrantHolder]

    /// Every device holding a Profile this device holds (`GET /api/v1/profile-grants/holders`).
    func profileHolders(
        home: HomeClientBaseURL,
        credential: Data
    ) async throws -> [HomeProfileGrantHolder]

    /// `POST /api/v1/profile-grants/{grant_id}/approve|reject|revoke`.
    func decideProfileGrant(
        home: HomeClientBaseURL,
        credential: Data,
        grantID: String,
        action: HomeProfileGrantAction
    ) async throws -> HomeProfileGrantDecision
}

struct URLSessionHomeClientService: HomeClientService, CustomStringConvertible {
    private let transport: any HomeHTTPTransport

    init(transport: any HomeHTTPTransport = URLSessionHomeHTTPTransport()) {
        self.transport = transport
    }

    var description: String { "URLSessionHomeClientService" }

    func submitEnrollment(
        home: HomeClientBaseURL,
        _ submission: HomeEnrollmentSubmission
    ) async throws -> HomeEnrollmentPendingRequest {
        let request = try makeRequest(
            home.apiURL("/api/v1/enrollment/requests"),
            method: "POST",
            body: submission
        )
        return try await send(request, as: HomeEnrollmentPendingRequest.self)
    }

    func consumeEnrollment(
        home: HomeClientBaseURL,
        requestID: String,
        enrollmentCode: String
    ) async throws -> HomeCredentialMaterial {
        let request = try makeRequest(
            home.apiURL("/api/v1/enrollment/requests/\(try pathSegment(requestID))/consume"),
            method: "POST",
            body: HomeEnrollmentConsumeBody(enrollmentCode: enrollmentCode)
        )
        return try await send(request, as: HomeCredentialMaterial.self)
    }

    func renewCredential(
        home: HomeClientBaseURL,
        deviceID: String,
        credential: Data,
        requestID: String,
        generation: Int
    ) async throws -> HomeCredentialMaterial {
        let request = try makeRequest(
            home.apiURL("/api/v1/devices/\(try pathSegment(deviceID))/credentials/renew"),
            method: "POST",
            body: HomeCredentialRenewBody(requestID: requestID, generation: generation),
            credential: credential
        )
        return try await send(request, as: HomeCredentialMaterial.self)
    }

    func deviceConfiguration(
        home: HomeClientBaseURL,
        deviceID: String,
        credential: Data
    ) async throws -> HomeClientDeviceConfiguration {
        let request = try makeRequest(
            home.apiURL("/api/v1/devices/\(try pathSegment(deviceID))/configuration"),
            method: "GET",
            body: Optional<HomeCredentialRenewBody>.none,
            credential: credential
        )
        return try await send(request, as: HomeClientDeviceConfiguration.self)
    }

    func claimConversation(
        home: HomeClientBaseURL,
        credential: Data,
        _ claim: HomeClientClaimRequest
    ) async throws -> HomeClientClaimGrant {
        let request = try makeRequest(
            home.apiURL("/api/v1/client-claims"),
            method: "POST",
            body: claim,
            credential: credential
        )
        let grant = try await send(request, as: HomeClientClaimGrant.self)
        guard grant.claimID == claim.claimID,
              grant.configurationRevision == claim.configurationRevision else {
            throw HomeClientServiceError.invalidResponse
        }
        if case .resume(let sessionRef) = claim.session,
           !grant.session.resumed || grant.session.sessionRef != sessionRef {
            // Home must bind exactly the session that was asked for.
            throw HomeClientServiceError.invalidResponse
        }
        return grant
    }

    func listSessions(
        home: HomeClientBaseURL,
        credential: Data,
        _ list: HomeClientSessionListRequest
    ) async throws -> [HomeClientSessionSummary] {
        let request = try makeRequest(
            home.apiURL("/api/v1/client-sessions/list"),
            method: "POST",
            body: list,
            credential: credential
        )
        return try await send(request, as: HomeClientSessionList.self).sessions
    }

    func claimSession(
        home: HomeClientBaseURL,
        credential: Data,
        _ lookup: HomeClientClaimSessionRequest
    ) async throws -> HomeClientClaimSessionLookup {
        let request = try makeRequest(
            home.apiURL("/api/v1/client-claims/session"),
            method: "POST",
            body: lookup,
            credential: credential
        )
        return try await send(request, as: HomeClientClaimSessionLookup.self)
    }

    func pendingProfileGrants(
        home: HomeClientBaseURL,
        credential: Data
    ) async throws -> [HomeProfileGrantHolder] {
        let request = try makeRequest(
            home.apiURL("/api/v1/profile-grants/pending"),
            method: "GET",
            body: Optional<HomeProfileGrantActionBody>.none,
            credential: credential
        )
        return try await send(request, as: HomeProfileGrantPendingList.self).pending
    }

    func profileHolders(
        home: HomeClientBaseURL,
        credential: Data
    ) async throws -> [HomeProfileGrantHolder] {
        let request = try makeRequest(
            home.apiURL("/api/v1/profile-grants/holders"),
            method: "GET",
            body: Optional<HomeProfileGrantActionBody>.none,
            credential: credential
        )
        return try await send(request, as: HomeProfileGrantHolderList.self).holders
    }

    func decideProfileGrant(
        home: HomeClientBaseURL,
        credential: Data,
        grantID: String,
        action: HomeProfileGrantAction
    ) async throws -> HomeProfileGrantDecision {
        let request = try makeRequest(
            home.apiURL("/api/v1/profile-grants/\(try pathSegment(grantID))/\(action.rawValue)"),
            method: "POST",
            body: HomeProfileGrantActionBody(),
            credential: credential
        )
        let decision = try await send(request, as: HomeProfileGrantDecision.self)
        guard decision.grantID == grantID else { throw HomeClientServiceError.invalidResponse }
        return decision
    }

    private func makeRequest<Body: Encodable>(
        _ url: URL,
        method: String,
        body: Body?,
        credential: Data? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        if let credential {
            guard !credential.isEmpty else { throw HomeClientServiceError.denied(.unauthorized) }
            request.setValue(
                "Device \(String(decoding: credential, as: UTF8.self))",
                forHTTPHeaderField: "Authorization"
            )
        }
        return request
    }

    private func send<Response: Decodable>(
        _ request: URLRequest,
        as type: Response.Type
    ) async throws -> Response {
        let data: Data
        let response: HomeHTTPResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HomeClientServiceError.transportUnavailable
        }
        guard response.statusCode == 200 else {
            if let envelope = try? JSONDecoder().decode(HomeClientErrorEnvelope.self, from: data),
               let denial = HomeClientDenial(rawValue: envelope.code) {
                throw HomeClientServiceError.denied(denial)
            }
            if response.statusCode == 401 { throw HomeClientServiceError.denied(.unauthorized) }
            throw HomeClientServiceError.unexpectedStatus(response.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw HomeClientServiceError.invalidResponse
        }
    }

    private func pathSegment(_ value: String) throws -> String {
        guard !value.isEmpty,
              let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) else {
            throw HomeClientServiceError.invalidResponse
        }
        return encoded
    }
}

/// Deterministic Home for tests and the Debug fixture. It never opens a
/// socket and records only non-secret request shapes.
actor FakeHomeClientService: HomeClientService {
    enum Call: Equatable, Sendable {
        case submit
        case consume
        case renew(generation: Int)
        case configuration
        case claim(grantID: String, revision: Int)
        case listSessions(grantID: String)
        case claimSession
        case pendingGrants
        case holders
        case decide(grantID: String, action: HomeProfileGrantAction)
    }

    /// Grants waiting for this device's decision, and every holder, as Home lists them.
    var pendingGrants: [HomeProfileGrantHolder] = []
    var holders: [HomeProfileGrantHolder] = []
    /// Errors answered by the pending and holder lists, in order; the last one repeats.
    var pendingErrors: [HomeClientServiceError] = []
    var holdersError: HomeClientServiceError?
    private var holdNextHolders = false
    private var heldHolders: CheckedContinuation<Void, Never>?
    /// Errors answered for a decision on one grant.
    var decisionErrors: [String: HomeClientServiceError] = [:]

    /// The Profile's sessions, newest first, as the list route returns them.
    var sessions: [HomeClientSessionSummary] = []
    var listError: HomeClientServiceError?
    /// Session choices of every claim, in order.
    private(set) var sessionChoices: [HomeClientSessionChoice] = []
    /// Denials for a resume of a given session reference.
    var sessionDenials: [String: HomeClientDenial] = [:]
    /// A denial for `most_recent` claims (e.g. the latest session is busy).
    var mostRecentDenial: HomeClientDenial?
    /// The session reference each claimed handle is bound to.
    private var sessionRefsByHandle: [String: String] = [:]
    private var newSessionCounter = 0

    private(set) var calls: [Call] = []
    private(set) var submissions: [HomeEnrollmentSubmission] = []
    private(set) var renewRequestIDs: [String] = []
    private(set) var credentialsSeen: [Data] = []

    var pendingRequest = HomeEnrollmentPendingRequest(
        requestID: "request-1",
        confirmationCode: "K7Q4MX2P",
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    var submitError: HomeClientServiceError?
    /// Consume answers in order; the last one repeats.
    var consumeResults: [Result<HomeCredentialMaterial, HomeClientServiceError>] = []
    var renewResult: Result<HomeCredentialMaterial, HomeClientServiceError>?
    var configurationResults: [Result<HomeClientDeviceConfiguration, HomeClientServiceError>] = []
    var claimResults: [Result<String, HomeClientServiceError>] = []
    /// Denials answered for one grant regardless of `claimResults`.
    var deniedGrants: [String: HomeClientDenial] = [:]
    private var claimCounter = 0

    init() {}

    func resetCalls() {
        calls.removeAll()
        sessionChoices.removeAll()
    }

    func setConsumeResults(_ results: [Result<HomeCredentialMaterial, HomeClientServiceError>]) {
        consumeResults = results
    }

    func setRenewResult(_ result: Result<HomeCredentialMaterial, HomeClientServiceError>?) {
        renewResult = result
    }

    func setConfigurationResults(_ results: [Result<HomeClientDeviceConfiguration, HomeClientServiceError>]) {
        configurationResults = results
    }

    func setClaimResults(_ results: [Result<String, HomeClientServiceError>]) {
        claimResults = results
    }

    func setDeniedGrants(_ denials: [String: HomeClientDenial]) {
        deniedGrants = denials
    }

    func setSessions(_ sessions: [HomeClientSessionSummary]) {
        self.sessions = sessions
    }

    func setListError(_ error: HomeClientServiceError?) {
        listError = error
    }

    func setSessionDenials(_ denials: [String: HomeClientDenial]) {
        sessionDenials = denials
    }

    func setMostRecentDenial(_ denial: HomeClientDenial?) {
        mostRecentDenial = denial
    }

    /// Simulates a new session's first accepted turn giving it a reference.
    func assignSessionRef(_ sessionRef: String, toHandle handle: String) {
        sessionRefsByHandle[handle] = sessionRef
    }

    func setSubmitError(_ error: HomeClientServiceError?) {
        submitError = error
    }

    func setPendingRequest(_ request: HomeEnrollmentPendingRequest) {
        pendingRequest = request
    }

    func submitEnrollment(
        home: HomeClientBaseURL,
        _ submission: HomeEnrollmentSubmission
    ) async throws -> HomeEnrollmentPendingRequest {
        calls.append(.submit)
        submissions.append(submission)
        if let submitError { throw submitError }
        return pendingRequest
    }

    func consumeEnrollment(
        home: HomeClientBaseURL,
        requestID: String,
        enrollmentCode: String
    ) async throws -> HomeCredentialMaterial {
        calls.append(.consume)
        guard !consumeResults.isEmpty else { throw HomeClientServiceError.denied(.approvalPending) }
        let result = consumeResults.count > 1 ? consumeResults.removeFirst() : consumeResults[0]
        return try result.get()
    }

    func renewCredential(
        home: HomeClientBaseURL,
        deviceID: String,
        credential: Data,
        requestID: String,
        generation: Int
    ) async throws -> HomeCredentialMaterial {
        calls.append(.renew(generation: generation))
        renewRequestIDs.append(requestID)
        credentialsSeen.append(credential)
        guard let renewResult else { throw HomeClientServiceError.denied(.conflict) }
        return try renewResult.get()
    }

    func deviceConfiguration(
        home: HomeClientBaseURL,
        deviceID: String,
        credential: Data
    ) async throws -> HomeClientDeviceConfiguration {
        calls.append(.configuration)
        credentialsSeen.append(credential)
        guard !configurationResults.isEmpty else {
            return HomeClientDeviceConfiguration(revision: 1, clientGrants: [])
        }
        let result = configurationResults.count > 1
            ? configurationResults.removeFirst()
            : configurationResults[0]
        return try result.get()
    }

    func claimConversation(
        home: HomeClientBaseURL,
        credential: Data,
        _ request: HomeClientClaimRequest
    ) async throws -> HomeClientClaimGrant {
        calls.append(.claim(grantID: request.grantID, revision: request.configurationRevision))
        credentialsSeen.append(credential)
        sessionChoices.append(request.session)
        claimCounter += 1
        if let denial = deniedGrants[request.grantID] {
            throw HomeClientServiceError.denied(denial)
        }
        let session: HomeClaimedSession
        switch request.session {
        case .new:
            session = HomeClaimedSession(resumed: false, sessionRef: nil)
        case .mostRecent:
            if let mostRecentDenial {
                throw HomeClientServiceError.denied(mostRecentDenial)
            }
            // Home falls back to a new session when the Profile has none.
            session = sessions.first.map { HomeClaimedSession(resumed: true, sessionRef: $0.sessionRef) }
                ?? HomeClaimedSession(resumed: false, sessionRef: nil)
        case .resume(let sessionRef):
            if let denial = sessionDenials[sessionRef] {
                throw HomeClientServiceError.denied(denial)
            }
            guard sessions.contains(where: { $0.sessionRef == sessionRef }) else {
                throw HomeClientServiceError.denied(.sessionUnavailable)
            }
            session = HomeClaimedSession(resumed: true, sessionRef: sessionRef)
        }
        let handle: String
        if !claimResults.isEmpty {
            let result = claimResults.count > 1 ? claimResults.removeFirst() : claimResults[0]
            handle = try result.get()
        } else {
            handle = "fake-client-claim-\(claimCounter)"
        }
        if let sessionRef = session.sessionRef {
            sessionRefsByHandle[handle] = sessionRef
        }
        return HomeClientClaimGrant(
            claimID: request.claimID,
            configurationRevision: request.configurationRevision,
            conversationHandle: handle,
            session: session
        )
    }

    func listSessions(
        home: HomeClientBaseURL,
        credential: Data,
        _ request: HomeClientSessionListRequest
    ) async throws -> [HomeClientSessionSummary] {
        calls.append(.listSessions(grantID: request.grantID))
        credentialsSeen.append(credential)
        if let listError { throw listError }
        return Array(sessions.prefix(request.limit))
    }

    func claimSession(
        home: HomeClientBaseURL,
        credential: Data,
        _ request: HomeClientClaimSessionRequest
    ) async throws -> HomeClientClaimSessionLookup {
        calls.append(.claimSession)
        credentialsSeen.append(credential)
        return HomeClientClaimSessionLookup(sessionRef: sessionRefsByHandle[request.conversationHandle])
    }

    func setPendingGrants(_ grants: [HomeProfileGrantHolder]) {
        pendingGrants = grants
    }

    func setHolders(_ holders: [HomeProfileGrantHolder]) {
        self.holders = holders
    }

    func setPendingErrors(_ errors: [HomeClientServiceError]) {
        pendingErrors = errors
    }

    func setHoldersError(_ error: HomeClientServiceError?) {
        holdersError = error
    }

    /// Makes the next holder list wait until `releaseHeldHoldersList()`, so a
    /// test can overlap two loads.
    func holdNextHoldersList() {
        holdNextHolders = true
    }

    var isHoldingHoldersList: Bool { heldHolders != nil }

    func releaseHeldHoldersList() {
        heldHolders?.resume()
        heldHolders = nil
    }

    func setDecisionErrors(_ errors: [String: HomeClientServiceError]) {
        decisionErrors = errors
    }

    func pendingProfileGrants(
        home: HomeClientBaseURL,
        credential: Data
    ) async throws -> [HomeProfileGrantHolder] {
        calls.append(.pendingGrants)
        credentialsSeen.append(credential)
        if !pendingErrors.isEmpty {
            throw pendingErrors.count > 1 ? pendingErrors.removeFirst() : pendingErrors[0]
        }
        return pendingGrants
    }

    func profileHolders(
        home: HomeClientBaseURL,
        credential: Data
    ) async throws -> [HomeProfileGrantHolder] {
        calls.append(.holders)
        credentialsSeen.append(credential)
        let answer = holders
        if holdNextHolders {
            holdNextHolders = false
            await withCheckedContinuation { heldHolders = $0 }
        }
        if let holdersError { throw holdersError }
        return answer
    }

    /// Applies the decision the way Home does: approve activates a pending
    /// grant, reject removes it, revoke removes a holder.
    func decideProfileGrant(
        home: HomeClientBaseURL,
        credential: Data,
        grantID: String,
        action: HomeProfileGrantAction
    ) async throws -> HomeProfileGrantDecision {
        calls.append(.decide(grantID: grantID, action: action))
        credentialsSeen.append(credential)
        if let error = decisionErrors[grantID] { throw error }
        switch action {
        case .approve, .reject:
            guard let index = pendingGrants.firstIndex(where: { $0.grantID == grantID }) else {
                throw HomeClientServiceError.denied(.notFound)
            }
            let grant = pendingGrants.remove(at: index)
            holders.removeAll { $0.grantID == grantID }
            guard action == .approve else {
                return HomeProfileGrantDecision(grantID: grantID, status: .rejected)
            }
            holders.append(HomeProfileGrantHolder(
                grantID: grant.grantID,
                deviceLabel: grant.deviceLabel,
                deviceType: grant.deviceType,
                profileLabel: grant.profileLabel,
                status: .active,
                createdAt: grant.createdAt
            ))
            return HomeProfileGrantDecision(grantID: grantID, status: .active)
        case .revoke:
            guard holders.contains(where: { $0.grantID == grantID })
                || pendingGrants.contains(where: { $0.grantID == grantID }) else {
                throw HomeClientServiceError.denied(.notFound)
            }
            holders.removeAll { $0.grantID == grantID }
            pendingGrants.removeAll { $0.grantID == grantID }
            return HomeProfileGrantDecision(grantID: grantID, status: .revoked)
        }
    }
}
