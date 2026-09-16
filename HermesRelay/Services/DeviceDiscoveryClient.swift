import Foundation

enum DeviceDiscoveryError: Error, Equatable, Sendable {
    case lanUnavailable
    case manualPairingUnavailable
    case invalidIdentifier
    case deviceNotFound
    case connectionFailed
    case unexpectedResponse
    case transportUnavailable
    case discoveryInProgress

    var userMessage: String {
        switch self {
        case .lanUnavailable:
            "Device discovery is unavailable. Try manual pairing."
        case .manualPairingUnavailable:
            "Manual pairing is unavailable. Check the Device and try again."
        case .invalidIdentifier:
            "Enter a valid Device identifier."
        case .deviceNotFound:
            "That Device could not be found. Try discovery again."
        case .connectionFailed:
            "The Device could not be connected. Try again."
        case .unexpectedResponse:
            "The Device identity could not be verified. Try again."
        case .transportUnavailable:
            "Device discovery is not configured yet. Try again when a Device transport is available."
        case .discoveryInProgress:
            "Finish Device discovery before connecting."
        }
    }
}

enum DeviceAdministrationError: Error, Equatable, Sendable {
    case approvalFailed
    case configurationFailed
    case revocationFailed
    case reEnrollmentFailed
    case unexpectedResponse
    case transportUnavailable

    var userMessage: String {
        switch self {
        case .approvalFailed:
            "The Device could not be approved. Try again."
        case .configurationFailed:
            "The Device setup could not be saved. Try again."
        case .revocationFailed:
            "Device access could not be revoked. It remains unavailable until you retry."
        case .reEnrollmentFailed:
            "The Device could not be re-enrolled. It remains unavailable. Try again."
        case .unexpectedResponse:
            "The Device identity could not be verified. Try again."
        case .transportUnavailable:
            "Device administration is not configured yet. Try again when a Device transport is available."
        }
    }
}

/// Adapter boundary for physical Device identity discovery.
///
/// Implementations must keep discovery and connection side-effect free: these
/// operations may observe and verify a Device, but must not approve it, issue
/// credentials, wake it, capture audio, or submit a Hermes turn.
protocol DeviceDiscoveryClient: Sendable {
    /// Whether this adapter can identify a Device through the manual fallback.
    /// The production placeholder reports false so the UI never offers an
    /// action that is guaranteed to fail.
    var supportsManualPairing: Bool { get }
    func discover() async throws -> DeviceDiscoverySnapshot
    /// Opens the adapter's read-only identity connection and returns only
    /// after the shared Device handshake has confirmed the requested ID.
    func connect(to device: HouseholdDevice) async throws -> DeviceConnectionReceipt
    func identifyManually(_ identifier: String) async throws -> HouseholdDevice
}

/// Adapter boundary for the trust transition and ordered setup that follows
/// identity discovery. A successful approval receipt asserts that the future
/// adapter provisioned an individual revocable credential; no secret bytes are
/// returned to the app model. Configuration is not active until its receipt
/// confirms the complete Room and Wake Mapping publish.
protocol DeviceAdministrationClient: Sendable {
    func approve(_ device: HouseholdDevice) async throws -> DeviceApprovalReceipt
    /// Revokes the Device Credential and Hermes access. The receipt contains
    /// identity only; credential material never crosses this boundary.
    func revoke(_ device: HouseholdDevice) async throws -> DeviceRevocationReceipt
    /// Starts explicit re-enrollment with a fresh credential. This receipt
    /// never promotes the Device to Ready; ordered setup must still complete.
    func reEnroll(_ device: HouseholdDevice) async throws -> DeviceReenrollmentReceipt
    func configure(
        _ configuration: DeviceSetupConfiguration
    ) async throws -> DeviceConfigurationReceipt
    /// Verifies the currently published Device identity and mapping. A
    /// successful `.verified` receipt is the only authority that may restore
    /// an active state after discovery; the production adapter remains
    /// unavailable until the shared Device contract exists.
    func verify(
        _ device: HouseholdDevice,
        against configuration: DeviceSetupConfiguration
    ) async throws -> DeviceVerificationReceipt
}

/// Typed boundary for the single local Home service. The service owns the
/// household snapshot and rejects writes based on a stale revision; this app
/// does not guess the production HTTP schema until the shared contract lands.
protocol HomeServiceClient: Sendable {
    /// Whether the selected Profile has an approved Home route. The default
    /// keeps deterministic and already-configured test clients Home-backed.
    func hasApprovedRoute() async throws -> Bool
    func fetchConfiguration() async throws -> HomeConfigurationSnapshot
    func publish(
        _ configuration: HomeConfigurationSnapshot,
        expectedRevision: Int
    ) async throws -> HomeConfigurationSnapshot
}

extension HomeServiceClient {
    func hasApprovedRoute() async throws -> Bool { true }
}

enum HomeServiceError: Error, Equatable, Sendable {
    case notConfigured
    case invalidRequest
    case notFound
    case revisionConflict
    case invalidConfiguration
    case invalidEndpoint
    case invalidResponse
    case missingCredential
    case unauthorized
    case serviceUnavailable
    case timeout
    case transportUnavailable

    var userMessage: String {
        switch self {
        case .notConfigured:
            "No Home route is configured for this Profile."
        case .invalidRequest:
            "Home rejected the configuration request. Check the Device settings and try again."
        case .notFound:
            "Home no longer has that Room, Device, or Wake Mapping. Reload before trying again."
        case .revisionConflict:
            "Home configuration changed on another Device. Reload before publishing."
        case .invalidConfiguration:
            "Home configuration is invalid. Fix the highlighted Device settings and try again."
        case .invalidEndpoint:
            "The Home route is invalid. Use the approved Home service endpoint."
        case .invalidResponse:
            "Home returned an invalid response. Keep the edit pending and reload before retrying; the publish result may be unknown."
        case .missingCredential:
            "The Home admin credential is not configured. Add it before managing Devices."
        case .unauthorized:
            "Home rejected the admin credential. Re-enter it before managing Devices."
        case .serviceUnavailable:
            "Home could not safely answer the request. The current configuration remains active."
        case .timeout:
            "Home did not answer before the request timed out. The current configuration remains active."
        case .transportUnavailable:
            "The local Home service is unavailable. Try again when it is running."
        }
    }
}

struct UnavailableHomeServiceClient: HomeServiceClient {
    func fetchConfiguration() async throws -> HomeConfigurationSnapshot {
        throw HomeServiceError.transportUnavailable
    }

    func publish(
        _ configuration: HomeConfigurationSnapshot,
        expectedRevision: Int
    ) async throws -> HomeConfigurationSnapshot {
        throw HomeServiceError.transportUnavailable
    }
}

/// Small transport seam for the Home HTTP adapter. Keeping URLSession behind
/// this protocol makes status, credential, and wire-shape handling testable
/// without starting a real Home process.
struct HomeHTTPResponse: Sendable {
    let statusCode: Int

    init(statusCode: Int) {
        self.statusCode = statusCode
    }
}

protocol HomeHTTPTransport: Sendable {
    func data(
        for request: URLRequest
    ) async throws -> (Data, HomeHTTPResponse)
}

final class HomeRedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class URLSessionHomeHTTPTransport: HomeHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let redirectDelegate: HomeRedirectRefusingDelegate

    init(configuration: URLSessionConfiguration = .ephemeral) {
        let delegate = HomeRedirectRefusingDelegate()
        self.redirectDelegate = delegate
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HomeHTTPResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw HomeServiceError.invalidResponse
        }
        return (data, HomeHTTPResponse(statusCode: response.statusCode))
    }
}

/// URLSession-backed adapter for Home's versioned administrative
/// configuration route. Home owns the complete snapshot and the revision;
/// this type only translates the shared HTTP contract into the iOS domain.
struct URLSessionHomeServiceClient: HomeServiceClient,
    CustomStringConvertible,
    CustomDebugStringConvertible {
    let baseURL: URL
    private let adminCredential: String
    private let transport: any HomeHTTPTransport

    init(
        baseURL: URL,
        adminCredential: String,
        transport: any HomeHTTPTransport = URLSessionHomeHTTPTransport()
    ) {
        self.baseURL = baseURL
        self.adminCredential = adminCredential
        self.transport = transport
    }

    var description: String { "URLSessionHomeServiceClient" }
    var debugDescription: String { description }

    func fetchConfiguration() async throws -> HomeConfigurationSnapshot {
        let request = try makeRequest(method: "GET")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw mapHTTPError(statusCode: response.statusCode, data: data)
        }
        return try decodeSnapshot(from: data)
    }

    func publish(
        _ configuration: HomeConfigurationSnapshot,
        expectedRevision: Int
    ) async throws -> HomeConfigurationSnapshot {
        guard expectedRevision >= 0, configuration.isValid else {
            throw HomeServiceError.invalidConfiguration
        }
        guard configuration.revision == expectedRevision else {
            throw HomeServiceError.revisionConflict
        }

        let envelope = try HomeConfigurationRequestEnvelope(
            configuration: configuration,
            expectedRevision: expectedRevision
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(envelope)
        let request = try makeRequest(method: "PUT", body: body)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw mapHTTPError(statusCode: response.statusCode, data: data)
        }
        return try decodeSnapshot(from: data)
    }

    private func makeRequest(
        method: String,
        body: Data? = nil
    ) throws -> URLRequest {
        guard !adminCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HomeServiceError.missingCredential
        }

        var request = URLRequest(url: try configurationURL())
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Bearer \(adminCredential)",
            forHTTPHeaderField: "Authorization"
        )
        if let body {
            request.httpBody = body
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
        }
        return request
    }

    private func configurationURL() throws -> URL {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ),
        let rawScheme = components.scheme?.lowercased(),
        ["http", "https", "ws", "wss"].contains(rawScheme),
        components.host != nil,
        components.user == nil,
        components.password == nil,
        components.query == nil,
        components.fragment == nil
        else {
            throw HomeServiceError.invalidEndpoint
        }

        components.scheme = switch rawScheme {
        case "ws": "http"
        case "wss": "https"
        default: rawScheme
        }

        switch components.path {
        case "", "/", "/api/v1", "/api/v1/":
            components.path = "/api/v1/configuration"
        case "/api/v1/bridge/ws":
            components.path = "/api/v1/configuration"
        case "/api/v1/configuration":
            break
        default:
            throw HomeServiceError.invalidEndpoint
        }

        guard let url = components.url else {
            throw HomeServiceError.invalidEndpoint
        }
        return url
    }

    private func send(
        _ request: URLRequest
    ) async throws -> (Data, HomeHTTPResponse) {
        do {
            return try await transport.data(for: request)
        } catch let error as HomeServiceError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw HomeServiceError.timeout
        } catch {
            throw HomeServiceError.transportUnavailable
        }
    }

    private func decodeSnapshot(from data: Data) throws -> HomeConfigurationSnapshot {
        do {
            let envelope = try JSONDecoder().decode(
                HomeConfigurationResponseEnvelope.self,
                from: data
            )
            guard envelope.schema == 1 else {
                throw HomeWireDecodingError.unsupportedSchema
            }
            return try envelope.snapshot.localSnapshot()
        } catch let error as HomeServiceError {
            throw error
        } catch {
            throw HomeServiceError.invalidResponse
        }
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> HomeServiceError {
        if let code = decodeRemoteErrorCode(from: data) {
            switch code {
            case "invalid_request":
                return .invalidRequest
            case "unauthorized":
                return .unauthorized
            case "not_found":
                return .notFound
            case "revision_conflict":
                return .revisionConflict
            case "service_unavailable":
                return .serviceUnavailable
            default:
                // Stable but unknown Home codes must not be guessed at. The
                // caller retains its verified state and can recover after a
                // compatible adapter is shipped.
                return .invalidResponse
            }
        }

        switch statusCode {
        case 401, 403:
            return .unauthorized
        case 409:
            return .revisionConflict
        case 400, 422:
            return .invalidRequest
        case 404:
            return .notFound
        case 502, 503, 504:
            return .serviceUnavailable
        default:
            return .invalidResponse
        }
    }

    private func decodeRemoteErrorCode(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder()
            .decode(HomeHTTPErrorEnvelope.self, from: data)
            .error
            .code
    }
}

/// Resolves the selected Profile's approved Home route and dedicated admin
/// credential for each request. Nothing secret is persisted in the Profile
/// JSON or retained by this value between requests.
struct ProfileHomeServiceClient: HomeServiceClient {
    let configurationStore: RelayConfigurationStore
    let routeProvider: any HomeApprovedRouteProvider
    let adminCredentialStore: any HomeAdminCredentialStore
    private let transport: any HomeHTTPTransport

    init(
        configurationStore: RelayConfigurationStore,
        routeProvider: any HomeApprovedRouteProvider,
        adminCredentialStore: any HomeAdminCredentialStore,
        transport: any HomeHTTPTransport = URLSessionHomeHTTPTransport()
    ) {
        self.configurationStore = configurationStore
        self.routeProvider = routeProvider
        self.adminCredentialStore = adminCredentialStore
        self.transport = transport
    }

    func fetchConfiguration() async throws -> HomeConfigurationSnapshot {
        try await makeClient().fetchConfiguration()
    }

    func hasApprovedRoute() async throws -> Bool {
        let profile: RelayProfile?
        do {
            profile = try await configurationStore.loadProfile()
        } catch {
            throw HomeServiceError.invalidEndpoint
        }
        guard let profile else { return false }

        let route: HomeApprovedRoute?
        do {
            route = try await routeProvider.approvedRoute(for: profile.id)
        } catch {
            throw HomeServiceError.invalidEndpoint
        }
        guard let route else { return false }
        do {
            try route.validate()
        } catch {
            throw HomeServiceError.invalidEndpoint
        }
        return true
    }

    func publish(
        _ configuration: HomeConfigurationSnapshot,
        expectedRevision: Int
    ) async throws -> HomeConfigurationSnapshot {
        try await makeClient().publish(
            configuration,
            expectedRevision: expectedRevision
        )
    }

    private func makeClient() async throws -> URLSessionHomeServiceClient {
        let profile: RelayProfile?
        do {
            profile = try await configurationStore.loadProfile()
        } catch {
            throw HomeServiceError.invalidEndpoint
        }
        guard let profile else {
            throw HomeServiceError.notConfigured
        }

        let route: HomeApprovedRoute?
        do {
            route = try await routeProvider.approvedRoute(for: profile.id)
        } catch {
            throw HomeServiceError.invalidEndpoint
        }
        guard let route else {
            throw HomeServiceError.notConfigured
        }
        do {
            try route.validate()
        } catch {
            throw HomeServiceError.invalidEndpoint
        }

        let credential: String?
        do {
            credential = try await adminCredentialStore.load(
                for: profile.id,
                approvedRoute: route
            )
        } catch {
            throw HomeServiceError.missingCredential
        }
        guard let credential else {
            throw HomeServiceError.missingCredential
        }

        return URLSessionHomeServiceClient(
            baseURL: route.endpoint,
            adminCredential: credential,
            transport: transport
        )
    }
}

private struct HomeConfigurationResponseEnvelope: Decodable {
    let schema: Int
    let snapshot: HomeWireConfigurationSnapshot

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, snapshot
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try HomeConfigurationWireCoding.requireExactKeys(
            decoder,
            allowed: CodingKeys.allCases
        )
        schema = try values.decode(Int.self, forKey: .schema)
        snapshot = try values.decode(
            HomeWireConfigurationSnapshot.self,
            forKey: .snapshot
        )
    }
}

private struct HomeHTTPErrorEnvelope: Decodable {
    let schema: Int
    let error: HomeHTTPErrorPayload

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, error
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try HomeConfigurationWireCoding.requireExactKeys(
            decoder,
            allowed: CodingKeys.allCases
        )
        schema = try values.decode(Int.self, forKey: .schema)
        guard schema == 1 else { throw HomeWireDecodingError.unsupportedSchema }
        error = try values.decode(HomeHTTPErrorPayload.self, forKey: .error)
    }
}

private struct HomeHTTPErrorPayload: Decodable {
    let code: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code
        case currentRevision = "current_revision"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try HomeConfigurationWireCoding.requireExactKeys(
            decoder,
            allowed: CodingKeys.allCases
        )
        code = try values.decode(String.self, forKey: .code)
        // The current revision is useful to an operator but the Home client
        // deliberately does not expose it as a second authority.
        _ = try values.decodeIfPresent(Int.self, forKey: .currentRevision)
    }
}

private struct HomeWireConfigurationSnapshot: Decodable {
    let revision: Int
    let rooms: [HomeWireRoom]
    let wakeMappings: [HomeWireWakeMapping]
    let devices: [HomeWireDevice]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case revision, rooms, devices
        case wakeMappings = "wake_mappings"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try HomeConfigurationWireCoding.requireExactKeys(
            decoder,
            allowed: CodingKeys.allCases
        )
        revision = try values.decode(Int.self, forKey: .revision)
        rooms = try values.decode([HomeWireRoom].self, forKey: .rooms)
        wakeMappings = try values.decode(
            [HomeWireWakeMapping].self,
            forKey: .wakeMappings
        )
        devices = try values.decode([HomeWireDevice].self, forKey: .devices)
    }

    func localSnapshot() throws -> HomeConfigurationSnapshot {
        guard revision >= 0 else {
            throw HomeWireDecodingError.invalidShape
        }
        guard devices.isEmpty || !rooms.isEmpty else {
            throw HomeWireDecodingError.invalidShape
        }

        var roomIDs = Set<String>()
        for room in rooms {
            guard roomIDs.insert(room.id).inserted else {
                throw HomeWireDecodingError.invalidShape
            }
        }

        let mappings = wakeMappings.map {
            CanonicalWakeMapping(
                id: CanonicalWakeMappingID($0.id),
                wakePhrase: $0.name
            )
        }
        let devices = devices.map { device in
            DeviceSetupConfiguration(
                deviceID: device.id,
                room: device.roomID,
                wakeMappings: mappings.map { mapping in
                    DeviceWakeMapping(
                        wakePhrase: mapping.wakePhrase,
                        profileIdentifier: device.profileID,
                        canonicalID: mapping.id
                    )
                },
                arbitrationPriority: device.priority,
                displayName: device.name,
                profileIdentifier: device.profileID,
                wakeClaimEnabled: device.capabilities.wakeClaim
            )
        }
        let snapshot = HomeConfigurationSnapshot(
            revision: revision,
            wakeMappings: mappings,
            devices: devices,
            rooms: rooms.map { HomeRoom(id: $0.id, name: $0.name) }
        )
        guard snapshot.isCompleteHomeSnapshot else {
            throw HomeWireDecodingError.invalidShape
        }
        return snapshot
    }
}

private struct HomeWireRoom: Decodable {
    let id: String
    let name: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try HomeConfigurationWireCoding.requireExactKeys(
            decoder,
            allowed: CodingKeys.allCases
        )
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        guard HomeConfigurationWireCoding.isValidIdentifier(id),
              HomeConfigurationWireCoding.isValidLabel(name)
        else {
            throw HomeWireDecodingError.invalidShape
        }
    }
}

private struct HomeWireWakeMapping: Decodable {
    let id: String
    let name: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try HomeConfigurationWireCoding.requireExactKeys(
            decoder,
            allowed: CodingKeys.allCases
        )
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        guard HomeConfigurationWireCoding.isValidIdentifier(id),
              HomeConfigurationWireCoding.isValidLabel(name)
        else {
            throw HomeWireDecodingError.invalidShape
        }
    }
}

private struct HomeConfigurationWireCapabilities: Decodable {
    let wakeClaim: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case wakeClaim = "wake_claim"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try HomeConfigurationWireCoding.requireExactKeys(
            decoder,
            allowed: CodingKeys.allCases
        )
        wakeClaim = try values.decode(Bool.self, forKey: .wakeClaim)
    }
}

private struct HomeWireDevice: Decodable {
    let id: String
    let name: String
    let roomID: String
    let profileID: String
    let priority: Int
    let capabilities: HomeConfigurationWireCapabilities

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, priority, capabilities
        case roomID = "room_id"
        case profileID = "profile_id"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try HomeConfigurationWireCoding.requireExactKeys(
            decoder,
            allowed: CodingKeys.allCases
        )
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        roomID = try values.decode(String.self, forKey: .roomID)
        profileID = try values.decode(String.self, forKey: .profileID)
        priority = try values.decode(Int.self, forKey: .priority)
        capabilities = try values.decode(
            HomeConfigurationWireCapabilities.self,
            forKey: .capabilities
        )
        guard HomeConfigurationWireCoding.isValidIdentifier(id),
              HomeConfigurationWireCoding.isValidLabel(name),
              HomeConfigurationWireCoding.isValidIdentifier(roomID),
              HomeConfigurationWireCoding.isValidIdentifier(profileID),
              priority > 0
        else {
            throw HomeWireDecodingError.invalidShape
        }
    }
}

private struct HomeConfigurationRequestEnvelope: Encodable {
    let schema = 1
    let expectedRevision: Int
    let snapshot: HomeConfigurationCandidate

    private enum CodingKeys: String, CodingKey {
        case schema
        case expectedRevision = "expected_revision"
        case snapshot
    }

    init(
        configuration: HomeConfigurationSnapshot,
        expectedRevision: Int
    ) throws {
        self.expectedRevision = expectedRevision
        snapshot = try HomeConfigurationCandidate(configuration: configuration)
    }
}

private struct HomeConfigurationCandidate: Encodable {
    let rooms: [HomeWireRoomPayload]
    let wakeMappings: [HomeWireWakeMappingPayload]
    let devices: [HomeWireDevicePayload]

    private enum CodingKeys: String, CodingKey {
        case rooms, devices
        case wakeMappings = "wake_mappings"
    }

    init(configuration: HomeConfigurationSnapshot) throws {
        guard configuration.isCompleteHomeSnapshot else {
            throw HomeServiceError.invalidConfiguration
        }

        // A Home PUT is a complete replacement. Missing Rooms are not a
        // request to invent labels from Device IDs; only Home may define them.
        let resolvedRooms = configuration.rooms
        guard configuration.devices.isEmpty || !resolvedRooms.isEmpty else {
            throw HomeServiceError.invalidConfiguration
        }

        guard resolvedRooms.allSatisfy(\HomeRoom.hasValidValues),
              configuration.wakeMappings.allSatisfy({ mapping in
                  HomeConfigurationWireCoding.isValidIdentifier(mapping.id.rawValue)
                      && HomeConfigurationWireCoding.isValidLabel(mapping.wakePhrase)
              })
        else {
            throw HomeServiceError.invalidConfiguration
        }

        let roomPayloads = resolvedRooms.map {
            HomeWireRoomPayload(id: $0.id, name: $0.name)
        }
        let mappingPayloads = configuration.wakeMappings.map {
            HomeWireWakeMappingPayload(id: $0.id.rawValue, name: $0.wakePhrase)
        }
        var devicePayloads: [HomeWireDevicePayload] = []
        for device in configuration.devices {
            guard let priority = device.arbitrationPriority,
                  resolvedRooms.contains(where: { $0.id == device.room })
            else {
                throw HomeServiceError.invalidConfiguration
            }

            let profiles = Set(
                device.wakeMappings.map(\DeviceWakeMapping.normalizedProfileIdentifier)
            )
            let profileID: String
            if let configuredProfile = device.profileIdentifier {
                let normalizedConfiguredProfile = configuredProfile.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard HomeConfigurationWireCoding.isValidIdentifier(configuredProfile),
                      profiles.isEmpty || profiles == Set([normalizedConfiguredProfile])
                else {
                    throw HomeServiceError.invalidConfiguration
                }
                profileID = configuredProfile
            } else {
                guard profiles.count == 1,
                      let inferredProfile = profiles.first,
                      HomeConfigurationWireCoding.isValidIdentifier(inferredProfile)
                else {
                    throw HomeServiceError.invalidConfiguration
                }
                profileID = inferredProfile
            }
            guard HomeConfigurationWireCoding.isValidIdentifier(profileID)
            else {
                throw HomeServiceError.invalidConfiguration
            }

            guard let name = device.displayName else {
                throw HomeServiceError.invalidConfiguration
            }
            guard HomeConfigurationWireCoding.isValidLabel(name) else {
                throw HomeServiceError.invalidConfiguration
            }
            devicePayloads.append(
                HomeWireDevicePayload(
                    id: device.deviceID,
                    name: name,
                    roomID: device.room,
                    profileID: profileID,
                    priority: priority,
                    capabilities: HomeWireCapabilitiesPayload(
                        wakeClaim: device.wakeClaimEnabled
                    )
                )
            )
        }

        rooms = roomPayloads
        wakeMappings = mappingPayloads
        devices = devicePayloads
    }
}

private struct HomeWireRoomPayload: Encodable {
    let id: String
    let name: String
}

private struct HomeWireWakeMappingPayload: Encodable {
    let id: String
    let name: String
}

private struct HomeWireCapabilitiesPayload: Encodable {
    let wakeClaim: Bool

    private enum CodingKeys: String, CodingKey {
        case wakeClaim = "wake_claim"
    }
}

private struct HomeWireDevicePayload: Encodable {
    let id: String
    let name: String
    let roomID: String
    let profileID: String
    let priority: Int
    let capabilities: HomeWireCapabilitiesPayload

    private enum CodingKeys: String, CodingKey {
        case id, name, priority, capabilities
        case roomID = "room_id"
        case profileID = "profile_id"
    }
}

private enum HomeConfigurationDynamicCodingKey: CodingKey {
    case string(String)

    init?(stringValue: String) {
        self = .string(stringValue)
    }

    var stringValue: String {
        if case let .string(value) = self { return value }
        return ""
    }

    init?(intValue: Int) { nil }
    var intValue: Int? { nil }
}

private enum HomeConfigurationWireCoding {
    static func requireExactKeys<K: CodingKey>(
        _ decoder: Decoder,
        allowed: [K]
    ) throws {
        let container = try decoder.container(
            keyedBy: HomeConfigurationDynamicCodingKey.self
        )
        let allowedNames = Set(allowed.map(\.stringValue))
        guard container.allKeys.allSatisfy({
            allowedNames.contains($0.stringValue)
        }) else {
            throw HomeWireDecodingError.unknownField
        }
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.count <= 128
    }

    static func isValidLabel(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 128
    }
}

protocol DeviceConfigurationStore: Sendable {
    func loadAll() async throws -> [DeviceConfigurationState]
    func save(_ state: DeviceConfigurationState) async throws
}

extension DeviceConfigurationStore {
    func load(for deviceID: String) async throws -> DeviceConfigurationState? {
        try await loadAll().first { $0.deviceID == deviceID }
    }
}

struct NoopDeviceConfigurationStore: DeviceConfigurationStore {
    func loadAll() async throws -> [DeviceConfigurationState] {
        []
    }

    func save(_ state: DeviceConfigurationState) async throws {}
}

enum DeviceConfigurationPersistenceFile {
    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent("device-configurations.json")
    }
}

actor JSONDeviceConfigurationStore: DeviceConfigurationStore {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func loadAll() async throws -> [DeviceConfigurationState] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder()
            .decode(PersistedDeviceConfigurations.self, from: data)
            .states
    }

    func save(_ state: DeviceConfigurationState) async throws {
        var statesByID: [String: DeviceConfigurationState] = [:]
        for existing in try await loadAll() {
            statesByID[existing.deviceID] = existing
        }
        statesByID[state.deviceID] = state
        let states = statesByID.values.sorted { $0.deviceID < $1.deviceID }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder
            .encode(PersistedDeviceConfigurations(states: states))
            .write(to: fileURL, options: .atomic)

        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: fileURL.path
        )
        #endif
    }
}

private struct PersistedDeviceConfigurations: Codable, Sendable {
    let states: [DeviceConfigurationState]
}

enum DeviceConfigurationStoreFactory {
    static func make(in directory: URL) -> any DeviceConfigurationStore {
        JSONDeviceConfigurationStore(
            fileURL: DeviceConfigurationPersistenceFile.url(in: directory)
        )
    }
}

enum DeviceSetupDraftStoreError: Error, Equatable, Sendable {
    case invalidDeviceID

    var userMessage: String {
        switch self {
        case .invalidDeviceID:
            "The Device setup draft could not be identified."
        }
    }
}

protocol DeviceSetupDraftStore: Sendable {
    func loadAll() async throws -> [DeviceSetupDraft]
    func save(_ draft: DeviceSetupDraft) async throws
    func delete(deviceID: String) async throws
}

extension DeviceSetupDraftStore {
    func load(for deviceID: String) async throws -> DeviceSetupDraft? {
        guard !deviceID.isEmpty, !deviceID.contains(where: { $0.isWhitespace }) else {
            throw DeviceSetupDraftStoreError.invalidDeviceID
        }
        return try await loadAll().first { $0.deviceID == deviceID }
    }
}

struct NoopDeviceSetupDraftStore: DeviceSetupDraftStore {
    func loadAll() async throws -> [DeviceSetupDraft] {
        []
    }

    func save(_ draft: DeviceSetupDraft) async throws {}

    func delete(deviceID: String) async throws {}
}

enum DeviceSetupDraftPersistenceFile {
    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent("device-setup-drafts.json")
    }
}

actor JSONDeviceSetupDraftStore: DeviceSetupDraftStore {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func loadAll() async throws -> [DeviceSetupDraft] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder()
            .decode(PersistedDeviceSetupDrafts.self, from: data)
            .drafts
    }

    func save(_ draft: DeviceSetupDraft) async throws {
        guard !draft.deviceID.isEmpty,
              !draft.deviceID.contains(where: { $0.isWhitespace })
        else {
            throw DeviceSetupDraftStoreError.invalidDeviceID
        }

        var draftsByID: [String: DeviceSetupDraft] = [:]
        for existing in try await loadAll() {
            draftsByID[existing.deviceID] = existing
        }
        draftsByID[draft.deviceID] = draft
        try write(Array(draftsByID.values).sorted { $0.deviceID < $1.deviceID })
    }

    func delete(deviceID: String) async throws {
        guard !deviceID.isEmpty, !deviceID.contains(where: { $0.isWhitespace }) else {
            throw DeviceSetupDraftStoreError.invalidDeviceID
        }

        let remaining = try await loadAll().filter { $0.deviceID != deviceID }
        if remaining.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } else {
            try write(remaining)
        }
    }

    private func write(_ drafts: [DeviceSetupDraft]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(PersistedDeviceSetupDrafts(drafts: drafts))
        try data.write(to: fileURL, options: .atomic)

        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: fileURL.path
        )
        #endif
    }
}

private struct PersistedDeviceSetupDrafts: Codable, Sendable {
    let drafts: [DeviceSetupDraft]
}

enum DeviceSetupDraftStoreFactory {
    static func make(in directory: URL) -> any DeviceSetupDraftStore {
        JSONDeviceSetupDraftStore(
            fileURL: DeviceSetupDraftPersistenceFile.url(in: directory)
        )
    }
}

extension DeviceDiscoveryClient {
    var supportsManualPairing: Bool { true }
}

struct UnavailableDeviceDiscoveryClient: DeviceDiscoveryClient {
    let supportsManualPairing = false

    func discover() async throws -> DeviceDiscoverySnapshot {
        throw DeviceDiscoveryError.lanUnavailable
    }

    func connect(to device: HouseholdDevice) async throws -> DeviceConnectionReceipt {
        throw DeviceDiscoveryError.connectionFailed
    }

    func identifyManually(_ identifier: String) async throws -> HouseholdDevice {
        throw DeviceDiscoveryError.manualPairingUnavailable
    }
}

struct UnavailableDeviceAdministrationClient: DeviceAdministrationClient {
    func approve(_ device: HouseholdDevice) async throws -> DeviceApprovalReceipt {
        throw DeviceAdministrationError.transportUnavailable
    }

    func revoke(_ device: HouseholdDevice) async throws -> DeviceRevocationReceipt {
        throw DeviceAdministrationError.transportUnavailable
    }

    func reEnroll(_ device: HouseholdDevice) async throws -> DeviceReenrollmentReceipt {
        throw DeviceAdministrationError.transportUnavailable
    }

    func configure(
        _ configuration: DeviceSetupConfiguration
    ) async throws -> DeviceConfigurationReceipt {
        throw DeviceAdministrationError.transportUnavailable
    }

    func verify(
        _ device: HouseholdDevice,
        against configuration: DeviceSetupConfiguration
    ) async throws -> DeviceVerificationReceipt {
        throw DeviceAdministrationError.transportUnavailable
    }
}

/// Selects the shipped unavailable adapter unless a Debug-only simulator
/// fixture is explicitly requested. The fixture is a visual verification aid;
/// it is not a production discovery transport.
enum DeviceDiscoveryClientFactory {
    static let fixtureLaunchArgument = "-HermesRelayDeviceDiscoveryFixture"

    static func make(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> any DeviceDiscoveryClient {
        #if DEBUG
        if arguments.contains(fixtureLaunchArgument) {
            return DebugDeviceDiscoveryFixtureClient()
        }
        #endif

        return UnavailableDeviceDiscoveryClient()
    }
}

enum DeviceAdministrationClientFactory {
    static let unavailableFixtureLaunchArgument = "-HermesRelayDeviceAdministrationUnavailable"
    static let revokedFixtureLaunchArgument = "-HermesRelayDeviceAdministrationRevoked"

    static func make(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> any DeviceAdministrationClient {
        #if DEBUG
        if arguments.contains(unavailableFixtureLaunchArgument) {
            return UnavailableDeviceAdministrationClient()
        }
        if arguments.contains(revokedFixtureLaunchArgument) {
            return DebugDeviceAdministrationFixtureClient(verificationStatus: .revoked)
        }
        if arguments.contains(DeviceDiscoveryClientFactory.fixtureLaunchArgument) {
            return DebugDeviceAdministrationFixtureClient()
        }
        #endif

        return UnavailableDeviceAdministrationClient()
    }
}

#if DEBUG
private struct DebugDeviceDiscoveryFixtureClient: DeviceDiscoveryClient {
    let supportsManualPairing = true

    private let approvedDevice = HouseholdDevice(
        id: "approved-kitchen-display",
        displayName: "Kitchen Display",
        kind: .display,
        trustState: .approved
    )
    private let successfulCandidate = HouseholdDevice(
        id: "unconfigured-hallway-puck",
        displayName: "Hallway Puck",
        kind: .puck,
        trustState: .unconfigured
    )
    private let failingCandidate = HouseholdDevice(
        id: "unconfigured-study-display",
        displayName: "Study Display",
        kind: .display,
        trustState: .unconfigured
    )

    func discover() async throws -> DeviceDiscoverySnapshot {
        DeviceDiscoverySnapshot(
            approvedDevices: [approvedDevice],
            unconfiguredDevices: [successfulCandidate, failingCandidate]
        )
    }

    func connect(to device: HouseholdDevice) async throws -> DeviceConnectionReceipt {
        try await Task.sleep(nanoseconds: 750_000_000)

        switch device.id {
        case successfulCandidate.id:
            return DeviceConnectionReceipt(deviceID: device.id)
        case failingCandidate.id:
            throw DeviceDiscoveryError.connectionFailed
        default:
            throw DeviceDiscoveryError.deviceNotFound
        }
    }

    func identifyManually(_ identifier: String) async throws -> HouseholdDevice {
        switch identifier {
        case successfulCandidate.id:
            return successfulCandidate
        case failingCandidate.id:
            return failingCandidate
        default:
            throw DeviceDiscoveryError.deviceNotFound
        }
    }
}

private struct DebugDeviceAdministrationFixtureClient: DeviceAdministrationClient {
    private let supportedDeviceIDs = [
        "unconfigured-hallway-puck",
        "unconfigured-study-display"
    ]
    private let verificationStatus: DeviceIdentityStatus

    init(verificationStatus: DeviceIdentityStatus = .verified) {
        self.verificationStatus = verificationStatus
    }

    func approve(_ device: HouseholdDevice) async throws -> DeviceApprovalReceipt {
        try await Task.sleep(nanoseconds: 500_000_000)
        guard supportedDeviceIDs.contains(device.id),
              device.trustState == .unconfigured
        else {
            throw DeviceAdministrationError.approvalFailed
        }
        return DeviceApprovalReceipt(deviceID: device.id)
    }

    func revoke(_ device: HouseholdDevice) async throws -> DeviceRevocationReceipt {
        try await Task.sleep(nanoseconds: 500_000_000)
        guard supportedDeviceIDs.contains(device.id),
              device.trustState == .approved
        else {
            throw DeviceAdministrationError.revocationFailed
        }
        return DeviceRevocationReceipt(deviceID: device.id)
    }

    func reEnroll(_ device: HouseholdDevice) async throws -> DeviceReenrollmentReceipt {
        try await Task.sleep(nanoseconds: 500_000_000)
        guard supportedDeviceIDs.contains(device.id),
              device.trustState == .approved
        else {
            throw DeviceAdministrationError.reEnrollmentFailed
        }
        return DeviceReenrollmentReceipt(deviceID: device.id)
    }

    func configure(
        _ configuration: DeviceSetupConfiguration
    ) async throws -> DeviceConfigurationReceipt {
        try await Task.sleep(nanoseconds: 500_000_000)
        guard supportedDeviceIDs.contains(configuration.deviceID) else {
            throw DeviceAdministrationError.configurationFailed
        }
        return DeviceConfigurationReceipt(
            deviceID: configuration.deviceID,
            configuration: configuration
        )
    }

    func verify(
        _ device: HouseholdDevice,
        against configuration: DeviceSetupConfiguration
    ) async throws -> DeviceVerificationReceipt {
        try await Task.sleep(nanoseconds: 500_000_000)
        guard supportedDeviceIDs.contains(device.id),
              device.trustState == .approved,
              configuration.deviceID == device.id
        else {
            throw DeviceAdministrationError.unexpectedResponse
        }
        return DeviceVerificationReceipt(
            deviceID: device.id,
            status: verificationStatus,
            configuration: configuration
        )
    }
}
#endif
