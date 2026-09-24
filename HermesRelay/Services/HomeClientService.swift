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
        return grant
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
    }

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
    private var claimCounter = 0

    init() {}

    func resetCalls() {
        calls.removeAll()
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
        claimCounter += 1
        if !claimResults.isEmpty {
            let result = claimResults.count > 1 ? claimResults.removeFirst() : claimResults[0]
            let handle = try result.get()
            return HomeClientClaimGrant(
                claimID: request.claimID,
                configurationRevision: request.configurationRevision,
                conversationHandle: handle
            )
        }
        return HomeClientClaimGrant(
            claimID: request.claimID,
            configurationRevision: request.configurationRevision,
            conversationHandle: "fake-client-claim-\(claimCounter)"
        )
    }
}
