import Foundation

// MARK: - Pairing input

enum HomeClientPairingError: Error, LocalizedError, Equatable, Sendable {
    case malformedLink
    case homeAddressRequired
    case homeAddressNotHTTPS
    case homeAddressHasCredentials
    case homeAddressHasQueryOrFragment
    case homeAddressHasPath
    case codeRequired
    case invalidCode

    var errorDescription: String? {
        switch self {
        case .malformedLink:
            return "This is not a Home pairing link. Open the link or scan the code shown on the Home pairing page."
        case .homeAddressRequired:
            return "Enter the Home address shown on the pairing page."
        case .homeAddressNotHTTPS:
            return "The Home address must use https://."
        case .homeAddressHasCredentials:
            return "The Home address must not contain a user name or password."
        case .homeAddressHasQueryOrFragment:
            return "The Home address must not contain a query or fragment."
        case .homeAddressHasPath:
            return "Enter only the Home address, without a path."
        case .codeRequired:
            return "Enter the pairing code shown on the Home pairing page."
        case .invalidCode:
            return "The pairing code is not valid. Check it against the Home pairing page."
        }
    }
}

/// The https origin of one Home. Every client route is derived from it; the
/// bridge is `wss://<same host:port>/api/v1/bridge/ws`.
struct HomeClientBaseURL: Codable, Hashable, Sendable {
    let url: URL

    init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HomeClientPairingError.homeAddressRequired }
        // A bare host is read as https; any other explicit scheme is rejected.
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: candidate) else {
            throw HomeClientPairingError.homeAddressRequired
        }
        try self.init(components: components)
    }

    init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw HomeClientPairingError.homeAddressRequired
        }
        try self.init(components: components)
    }

    private init(components: URLComponents) throws {
        guard components.scheme?.lowercased() == "https" else {
            throw HomeClientPairingError.homeAddressNotHTTPS
        }
        guard components.user == nil, components.password == nil else {
            throw HomeClientPairingError.homeAddressHasCredentials
        }
        guard components.query == nil, components.fragment == nil else {
            throw HomeClientPairingError.homeAddressHasQueryOrFragment
        }
        guard components.path.isEmpty || components.path == "/" else {
            throw HomeClientPairingError.homeAddressHasPath
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw HomeClientPairingError.homeAddressRequired
        }
        var normalized = URLComponents()
        normalized.scheme = "https"
        normalized.host = host
        // `https://host` and `https://host:443` are the same Home.
        normalized.port = components.port == 443 ? nil : components.port
        guard let url = normalized.url else {
            throw HomeClientPairingError.homeAddressRequired
        }
        self.url = url
    }

    /// `host` or `host:port`, for labels only.
    var displayName: String {
        let host = url.host ?? url.absoluteString
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    var bridgeEndpoint: URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = url.host
        components.port = url.port
        components.path = "/api/v1/bridge/ws"
        // Host and port come from a validated https origin.
        return components.url!
    }

    func apiURL(_ path: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = url.host
        components.port = url.port
        components.path = path
        return components.url!
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url.absoluteString)
    }
}

/// Home accepts a short code in any case, with or without its dash, and
/// passes a long URL-safe code through unchanged.
enum HomeEnrollmentCode {
    static let shortLength = 10
    private static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let tokenCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    static func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HomeClientPairingError.codeRequired }
        let compact = trimmed
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        if compact.count == shortLength, compact.allSatisfy(alphabet.contains) {
            return compact
        }
        guard (16...128).contains(trimmed.count),
              trimmed.allSatisfy(tokenCharacters.contains) else {
            throw HomeClientPairingError.invalidCode
        }
        return trimmed
    }
}

/// A pairing offer from a `hermes-home://pair` link, a QR code of that link,
/// or a typed short code plus Home address.
struct HomePairingInvitation: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    static let scheme = "hermes-home"

    let home: HomeClientBaseURL
    /// Held only in memory for the pairing attempt; never persisted or logged.
    let code: String

    init(code: String, homeAddress: String) throws {
        self.home = try HomeClientBaseURL(homeAddress)
        self.code = try HomeEnrollmentCode.normalize(code)
    }

    init(link: URL) throws {
        guard link.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "pair",
              components.path.isEmpty || components.path == "/",
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let items = components.queryItems,
              items.count == 2,
              Set(items.map(\.name)) == ["home", "code"],
              let home = items.first(where: { $0.name == "home" })?.value,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw HomeClientPairingError.malformedLink
        }
        self.home = try HomeClientBaseURL(home)
        self.code = try HomeEnrollmentCode.normalize(code)
    }

    init(linkText: String) throws {
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { throw HomeClientPairingError.malformedLink }
        try self.init(link: url)
    }

    static func isPairingLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    var description: String { "HomePairingInvitation(home: \(home.displayName), code: <redacted>)" }
    var debugDescription: String { description }
}

// MARK: - Wire models (HOME-NW-17)

enum HomeClientEndpointType: String, Codable, Sendable {
    case ios
    case macos

    static var current: HomeClientEndpointType {
        #if os(macOS)
        return .macos
        #else
        return .ios
        #endif
    }
}

struct HomeEnrollmentSubmission: Encodable, Equatable, Sendable, CustomStringConvertible {
    let enrollmentCode: String
    let endpointID: String
    let label: String
    let type: HomeClientEndpointType

    static let secureStorage = "platform_secure_store"
    static let requestedCapabilities = ["client_claim"]

    init(enrollmentCode: String, endpointID: UUID, label: String, type: HomeClientEndpointType) {
        self.enrollmentCode = enrollmentCode
        self.endpointID = endpointID.uuidString.lowercased()
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = String((trimmed.isEmpty ? "Apple device" : trimmed).prefix(128))
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case enrollmentCode = "enrollment_code"
        case endpointID = "endpoint_id"
        case label, type
        case requestedRooms = "requested_rooms"
        case requestedCapabilities = "requested_capabilities"
        case secureStorage = "secure_storage"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .schema)
        try values.encode(enrollmentCode, forKey: .enrollmentCode)
        try values.encode(endpointID, forKey: .endpointID)
        try values.encode(label, forKey: .label)
        try values.encode(type, forKey: .type)
        try values.encode([String](), forKey: .requestedRooms)
        try values.encode(Self.requestedCapabilities, forKey: .requestedCapabilities)
        try values.encode(Self.secureStorage, forKey: .secureStorage)
    }

    var description: String { "HomeEnrollmentSubmission(type: \(type.rawValue), code: <redacted>)" }
}

struct HomeEnrollmentConsumeBody: Encodable, Sendable {
    let enrollmentCode: String

    private enum CodingKeys: String, CodingKey {
        case schema
        case enrollmentCode = "enrollment_code"
        case secureStorage = "secure_storage"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .schema)
        try values.encode(enrollmentCode, forKey: .enrollmentCode)
        try values.encode(HomeEnrollmentSubmission.secureStorage, forKey: .secureStorage)
    }
}

/// The pending enrollment. `requestID` is non-secret; the confirmation code
/// is shown to the user to compare with the Home page.
struct HomeEnrollmentPendingRequest: Decodable, Equatable, Sendable {
    let requestID: String
    let confirmationCode: String
    let expiresAt: Date

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case requestID = "request_id"
        case confirmationCode = "confirmation_code"
        case expiresAt = "expires_at"
    }

    init(requestID: String, confirmationCode: String, expiresAt: Date) {
        self.requestID = requestID
        self.confirmationCode = confirmationCode
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        try HomeClientStrictKeys.require(decoder, allowed: CodingKeys.allCases)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schema) == 1 else {
            throw HomeWireDecodingError.unsupportedSchema
        }
        requestID = try HomeClientStrictKeys.identifier(values.decode(String.self, forKey: .requestID))
        confirmationCode = try values.decode(String.self, forKey: .confirmationCode)
        expiresAt = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .expiresAt))
        guard confirmationCode.count == 8 else { throw HomeWireDecodingError.invalidShape }
    }

    /// Shown in two groups of four, for example `K7Q4-MX2P`.
    var displayConfirmationCode: String {
        let midpoint = confirmationCode.index(confirmationCode.startIndex, offsetBy: 4)
        return "\(confirmationCode[..<midpoint])-\(confirmationCode[midpoint...])"
    }
}

struct HomeClientGrantStatus: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    static let active = HomeClientGrantStatus(rawValue: "active")
    static let pendingOwner = HomeClientGrantStatus(rawValue: "pending_owner")
}

/// One Profile grant as Home presents it: an opaque `grant_id` and a display
/// label. Home never sends the Profile ID.
struct HomeClientGrant: Codable, Equatable, Sendable {
    let grantID: String
    let label: String
    let status: HomeClientGrantStatus
    let available: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case grantID = "grant_id"
        case label, status, available
    }

    init(grantID: String, label: String, status: HomeClientGrantStatus, available: Bool) {
        self.grantID = grantID
        self.label = label
        self.status = status
        self.available = available
    }

    init(from decoder: Decoder) throws {
        try HomeClientStrictKeys.require(decoder, allowed: CodingKeys.allCases)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        grantID = try HomeClientStrictKeys.identifier(values.decode(String.self, forKey: .grantID))
        label = try values.decode(String.self, forKey: .label)
        status = try values.decode(HomeClientGrantStatus.self, forKey: .status)
        available = try values.decode(Bool.self, forKey: .available)
    }

    var isActive: Bool { status == .active }
}

/// Credential material from consume or renew. The value is kept as bytes
/// only long enough to write it to Keychain; every textual form is redacted.
struct HomeCredentialMaterial: Decodable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    let deviceID: String
    let credential: Data
    let generation: Int
    let expiresAt: Date
    let capabilities: [String]
    let clientGrants: [HomeClientGrant]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case deviceID = "device_id"
        case credential, generation
        case expiresAt = "expires_at"
        case scope
        case clientGrants = "client_grants"
    }

    private struct Scope: Decodable {
        let capabilities: [String]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case rooms, capabilities
            case wakeMappings = "wake_mappings"
        }

        init(from decoder: Decoder) throws {
            try HomeClientStrictKeys.require(decoder, allowed: CodingKeys.allCases)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            _ = try values.decode([String].self, forKey: .rooms)
            capabilities = try values.decode([String].self, forKey: .capabilities)
            _ = try values.decode([String].self, forKey: .wakeMappings)
        }
    }

    init(
        deviceID: String,
        credential: Data,
        generation: Int,
        expiresAt: Date,
        capabilities: [String] = ["client_claim"],
        clientGrants: [HomeClientGrant] = []
    ) {
        self.deviceID = deviceID
        self.credential = credential
        self.generation = generation
        self.expiresAt = expiresAt
        self.capabilities = capabilities
        self.clientGrants = clientGrants
    }

    init(from decoder: Decoder) throws {
        try HomeClientStrictKeys.require(decoder, allowed: CodingKeys.allCases)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schema) == 1 else {
            throw HomeWireDecodingError.unsupportedSchema
        }
        deviceID = try HomeClientStrictKeys.identifier(values.decode(String.self, forKey: .deviceID))
        let credentialText = try values.decode(String.self, forKey: .credential)
        guard !credentialText.isEmpty else { throw HomeWireDecodingError.invalidShape }
        credential = Data(credentialText.utf8)
        generation = try values.decode(Int.self, forKey: .generation)
        guard generation >= 1 else { throw HomeWireDecodingError.invalidShape }
        expiresAt = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .expiresAt))
        capabilities = try values.decode(Scope.self, forKey: .scope).capabilities
        clientGrants = try values.decodeIfPresent([HomeClientGrant].self, forKey: .clientGrants) ?? []
    }

    var description: String {
        "HomeCredentialMaterial(generation: \(generation), credential: <redacted>)"
    }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["generation": generation]) }
}

struct HomeCredentialRenewBody: Encodable, Sendable {
    let requestID: String
    let generation: Int

    private enum CodingKeys: String, CodingKey {
        case schema
        case requestID = "request_id"
        case generation
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .schema)
        try values.encode(requestID, forKey: .requestID)
        try values.encode(generation, forKey: .generation)
    }
}

/// `GET /api/v1/devices/{device_id}/configuration` as a personal client
/// sees it: the configuration revision beside its current grants.
struct HomeClientDeviceConfiguration: Decodable, Equatable, Sendable {
    let revision: Int
    let clientGrants: [HomeClientGrant]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, snapshot
    }

    private struct Snapshot: Decodable {
        let revision: Int
        let clientGrants: [HomeClientGrant]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case revision
            case wakeMappings = "wake_mappings"
            case clientGrants = "client_grants"
        }

        init(from decoder: Decoder) throws {
            try HomeClientStrictKeys.require(decoder, allowed: CodingKeys.allCases)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            revision = try values.decode(Int.self, forKey: .revision)
            // A personal client has no wake mappings; the list is ignored.
            _ = try values.decodeIfPresent([HomeJSONValue].self, forKey: .wakeMappings)
            clientGrants = try values.decodeIfPresent([HomeClientGrant].self, forKey: .clientGrants) ?? []
            guard revision >= 0 else { throw HomeWireDecodingError.invalidShape }
        }
    }

    init(revision: Int, clientGrants: [HomeClientGrant]) {
        self.revision = revision
        self.clientGrants = clientGrants
    }

    init(from decoder: Decoder) throws {
        try HomeClientStrictKeys.require(decoder, allowed: CodingKeys.allCases)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schema) == 1 else {
            throw HomeWireDecodingError.unsupportedSchema
        }
        let snapshot = try values.decode(Snapshot.self, forKey: .snapshot)
        revision = snapshot.revision
        clientGrants = snapshot.clientGrants
    }
}

/// `POST /api/v1/client-claims`. This slice always asks for a new session.
struct HomeClientClaimRequest: Encodable, Equatable, Sendable {
    let claimID: String
    let deviceID: String
    let configurationRevision: Int
    let grantID: String

    private enum CodingKeys: String, CodingKey {
        case schema
        case claimID = "claim_id"
        case deviceID = "device_id"
        case configurationRevision = "configuration_revision"
        case grantID = "grant_id"
        case session
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .schema)
        try values.encode(claimID, forKey: .claimID)
        try values.encode(deviceID, forKey: .deviceID)
        try values.encode(configurationRevision, forKey: .configurationRevision)
        try values.encode(grantID, forKey: .grantID)
        try values.encode(["mode": "new"], forKey: .session)
    }
}

/// A granted claim. Only the opaque handle is kept, in memory; the session
/// reference Home returns is not retained.
struct HomeClientClaimGrant: Decodable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    let claimID: String
    let configurationRevision: Int
    let conversationHandle: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case claimID = "claim_id"
        case decision
        case configurationRevision = "configuration_revision"
        case conversationHandle = "conversation_handle"
        case session
    }

    private struct Session: Decodable {
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case mode
            case sessionRef = "session_ref"
        }

        init(from decoder: Decoder) throws {
            try HomeClientStrictKeys.require(decoder, allowed: CodingKeys.allCases)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let mode = try values.decode(String.self, forKey: .mode)
            guard ["new", "resumed"].contains(mode) else { throw HomeWireDecodingError.invalidShape }
            _ = try values.decodeIfPresent(String.self, forKey: .sessionRef)
        }
    }

    init(claimID: String, configurationRevision: Int, conversationHandle: String) {
        self.claimID = claimID
        self.configurationRevision = configurationRevision
        self.conversationHandle = conversationHandle
    }

    init(from decoder: Decoder) throws {
        try HomeClientStrictKeys.require(decoder, allowed: CodingKeys.allCases)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schema) == 1 else {
            throw HomeWireDecodingError.unsupportedSchema
        }
        guard try values.decode(String.self, forKey: .decision) == "granted" else {
            throw HomeWireDecodingError.invalidShape
        }
        claimID = try values.decode(String.self, forKey: .claimID)
        configurationRevision = try values.decode(Int.self, forKey: .configurationRevision)
        conversationHandle = try values.decode(String.self, forKey: .conversationHandle)
        _ = try values.decode(Session.self, forKey: .session)
        guard !conversationHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HomeWireDecodingError.invalidShape
        }
    }

    var description: String { "HomeClientClaimGrant(handle: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["configurationRevision": configurationRevision]) }
}

/// Home's stable error codes on the personal-client routes.
enum HomeClientDenial: String, Equatable, Sendable {
    case approvalPending = "approval_pending"
    case rejected
    case expiredOrConsumed = "expired_or_consumed"
    case unauthorized
    case forbidden
    case notFound = "not_found"
    case conflict
    case invalidRequest = "invalid_request"
    case serviceUnavailable = "service_unavailable"
    case grantPending = "grant_pending"
    case profileUnavailable = "profile_unavailable"
    case clientClaimUnavailable = "client_claim_unavailable"
    case claimLimit = "claim_limit"
    case staleConfiguration = "stale_configuration"
    case sessionUnavailable = "session_unavailable"
    case sessionBusy = "session_busy"
    case configurationMigrationRequired = "configuration_migration_required"
}

enum HomeClientServiceError: Error, Equatable, Sendable {
    case denied(HomeClientDenial)
    case unexpectedStatus(Int)
    case invalidResponse
    case transportUnavailable
}

struct HomeClientErrorEnvelope: Decodable, Sendable {
    let code: String

    private enum CodingKeys: String, CodingKey { case schema, error }
    private struct Body: Decodable {
        let code: String
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decode(Body.self, forKey: .error).code
    }
}

// MARK: - Local pairing record

/// One app profile bound to one Home grant.
struct HomeClientPairedProfile: Codable, Equatable, Sendable {
    let profileID: UUID
    let grantID: String
}

/// The non-secret record of one Home pairing. The credential is in Keychain
/// under `HomeCredentialKeychain.account(forPairing:)`; no handle, Profile ID
/// or session identifier is ever written here.
struct HomeClientPairing: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let home: HomeClientBaseURL
    let endpointID: UUID
    var deviceID: String
    var generation: Int
    var credentialExpiresAt: Date
    var credentialUsable: Bool
    var grants: [HomeClientGrant]
    var profiles: [HomeClientPairedProfile]
    var pinnedRouteID: String?
    /// Set while a renewal is in flight so a crash can retry the same
    /// idempotent request instead of burning the generation.
    var pendingRenewalRequestID: String?
    /// Grants whose profile the user removed while the grant stayed active
    /// on Home. A refresh does not recreate them; a fresh re-pair clears them.
    var unboundGrantIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, home, endpointID, deviceID, generation
        case credentialExpiresAt, credentialUsable, grants, profiles
        case pinnedRouteID, pendingRenewalRequestID, unboundGrantIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decode(UUID.self, forKey: .id)
        home = try values.decode(HomeClientBaseURL.self, forKey: .home)
        endpointID = try values.decode(UUID.self, forKey: .endpointID)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        generation = try values.decode(Int.self, forKey: .generation)
        credentialExpiresAt = try values.decode(Date.self, forKey: .credentialExpiresAt)
        credentialUsable = try values.decode(Bool.self, forKey: .credentialUsable)
        grants = try values.decode([HomeClientGrant].self, forKey: .grants)
        profiles = try values.decode([HomeClientPairedProfile].self, forKey: .profiles)
        pinnedRouteID = try values.decodeIfPresent(String.self, forKey: .pinnedRouteID)
        pendingRenewalRequestID = try values.decodeIfPresent(String.self, forKey: .pendingRenewalRequestID)
        unboundGrantIDs = try values.decodeIfPresent([String].self, forKey: .unboundGrantIDs) ?? []
    }

    init(
        id: UUID = UUID(),
        home: HomeClientBaseURL,
        endpointID: UUID,
        deviceID: String,
        generation: Int,
        credentialExpiresAt: Date,
        credentialUsable: Bool = true,
        grants: [HomeClientGrant] = [],
        profiles: [HomeClientPairedProfile] = [],
        pinnedRouteID: String? = nil,
        pendingRenewalRequestID: String? = nil,
        unboundGrantIDs: [String] = [],
        schemaVersion: Int = HomeClientPairing.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.home = home
        self.endpointID = endpointID
        self.deviceID = deviceID
        self.generation = generation
        self.credentialExpiresAt = credentialExpiresAt
        self.credentialUsable = credentialUsable
        self.grants = grants
        self.profiles = profiles
        self.pinnedRouteID = pinnedRouteID
        self.pendingRenewalRequestID = pendingRenewalRequestID
        self.unboundGrantIDs = unboundGrantIDs
    }

    func grantID(for profileID: UUID) -> String? {
        profiles.first { $0.profileID == profileID }?.grantID
    }

    func profileID(for grantID: String) -> UUID? {
        profiles.first { $0.grantID == grantID }?.profileID
    }

    func grant(for profileID: UUID) -> HomeClientGrant? {
        guard let grantID = grantID(for: profileID) else { return nil }
        return grants.first { $0.grantID == grantID }
    }

    var approvedRoute: HomeApprovedRoute {
        HomeApprovedRoute(
            endpoint: home.bridgeEndpoint,
            identity: HomeRouteIdentity(
                routeClass: .home,
                id: pinnedRouteID ?? HomeRouteIdentity.pendingPinID
            ),
            householdBinding: home.displayName
        )
    }

    /// Home's contract fixes 90-day credentials renewable in the last 14
    /// days, so the Keychain reference is derived from `expires_at`.
    var credentialReference: HomeCredentialReference {
        Self.credentialReference(pairingID: id, expiresAt: credentialExpiresAt)
    }

    static func credentialReference(pairingID: UUID, expiresAt: Date) -> HomeCredentialReference {
        HomeCredentialReference(
            service: HomeCredentialKeychain.service,
            account: HomeCredentialKeychain.account(forPairing: pairingID),
            issuedAt: expiresAt.addingTimeInterval(-90 * 24 * 60 * 60),
            expiresAt: expiresAt,
            renewAfter: expiresAt.addingTimeInterval(-14 * 24 * 60 * 60),
            overlapUntil: nil
        )
    }

    /// Whole seconds keep the derived dates exact.
    static func normalizedExpiry(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    static func profileDisplayName(grantLabel: String, home: HomeClientBaseURL) -> String {
        let label = grantLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(label.isEmpty ? "Home" : label) · \(home.displayName)"
    }
}

// MARK: - Strict decoding

enum HomeClientStrictKeys {
    private struct AnyKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    static func require<K: CodingKey>(_ decoder: Decoder, allowed: [K]) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let names = Set(allowed.map(\.stringValue))
        guard container.allKeys.allSatisfy({ names.contains($0.stringValue) }) else {
            throw HomeWireDecodingError.unknownField
        }
    }

    static func identifier(_ value: String) throws -> String {
        guard (1...128).contains(value.count) else { throw HomeWireDecodingError.invalidShape }
        return value
    }
}
