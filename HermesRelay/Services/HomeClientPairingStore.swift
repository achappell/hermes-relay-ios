import Foundation

// MARK: - Pairing records

enum HomeClientPairingStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidStorage
    case unsupportedSchema
    case unknownPairing
    case routeIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .invalidStorage:
            return "The saved Home pairing could not be read."
        case .unsupportedSchema:
            return "The saved Home pairing uses an unsupported format."
        case .unknownPairing:
            return "This Home pairing no longer exists. Pair again."
        case .routeIdentityMismatch:
            return "Home answered on a different route than the one approved when pairing."
        }
    }
}

private struct HomeClientPairingFile: Codable, Sendable {
    var schemaVersion: Int
    var pairings: [HomeClientPairing]
    /// Stable per-install, per-Home endpoint IDs. They outlive a removed
    /// pairing so that pairing the same Home again replaces its generation.
    var endpointIDs: [String: UUID]

    static let empty = HomeClientPairingFile(
        schemaVersion: HomeClientPairing.currentSchemaVersion,
        pairings: [],
        endpointIDs: [:]
    )
}

/// Non-secret pairing records (Home URL, endpoint ID, device ID, generation,
/// per-profile grant, pinned route ID). Secrets live only in Keychain.
actor JSONHomeClientPairingStore: HomeRoutePinRecorder, HomeApprovedRouteProvider {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func pairings() throws -> [HomeClientPairing] {
        try readFile().pairings
    }

    func pairing(id: UUID) throws -> HomeClientPairing? {
        try readFile().pairings.first { $0.id == id }
    }

    func pairing(forProfile profileID: UUID) throws -> HomeClientPairing? {
        try readFile().pairings.first { $0.grantID(for: profileID) != nil }
    }

    func pairing(forHome home: HomeClientBaseURL) throws -> HomeClientPairing? {
        try readFile().pairings.first { $0.home == home }
    }

    func save(_ pairing: HomeClientPairing) throws {
        var file = try readFile()
        if let index = file.pairings.firstIndex(where: { $0.id == pairing.id }) {
            file.pairings[index] = pairing
        } else {
            file.pairings.append(pairing)
        }
        file.endpointIDs[pairing.home.url.absoluteString] = pairing.endpointID
        try write(file)
    }

    /// Applies `mutate` to the record as it is on disk now, so a copy read
    /// before an `await` never overwrites fields written in between (the
    /// route pin, a newer generation, profile mappings).
    @discardableResult
    func update(
        pairingID: UUID,
        _ mutate: (inout HomeClientPairing) throws -> Void
    ) throws -> HomeClientPairing {
        var file = try readFile()
        guard let index = file.pairings.firstIndex(where: { $0.id == pairingID }) else {
            throw HomeClientPairingStoreError.unknownPairing
        }
        let pinned = file.pairings[index].pinnedRouteID
        var pairing = file.pairings[index]
        try mutate(&pairing)
        // Only a fresh re-pair (`save`) may clear the pin.
        if pairing.pinnedRouteID == nil { pairing.pinnedRouteID = pinned }
        file.pairings[index] = pairing
        try write(file)
        return pairing
    }

    func remove(pairingID: UUID) throws {
        var file = try readFile()
        file.pairings.removeAll { $0.id == pairingID }
        try write(file)
    }

    func endpointID(for home: HomeClientBaseURL) throws -> UUID {
        var file = try readFile()
        if let existing = file.endpointIDs[home.url.absoluteString] { return existing }
        let endpointID = UUID()
        file.endpointIDs[home.url.absoluteString] = endpointID
        try write(file)
        return endpointID
    }

    /// Unbinds one app profile. Returns the pairing when that was its last
    /// profile; the record is then removed and the caller deletes the
    /// credential.
    func removeProfile(_ profileID: UUID) throws -> HomeClientPairing? {
        var file = try readFile()
        guard let index = file.pairings.firstIndex(where: { $0.grantID(for: profileID) != nil }) else {
            return nil
        }
        var pairing = file.pairings[index]
        // The grant stays active on Home; remember that the user removed its
        // profile so a refresh does not recreate it.
        for removed in pairing.profiles where removed.profileID == profileID
            && !pairing.unboundGrantIDs.contains(removed.grantID) {
            pairing.unboundGrantIDs.append(removed.grantID)
        }
        pairing.profiles.removeAll { $0.profileID == profileID }
        if pairing.profiles.isEmpty {
            file.pairings.remove(at: index)
            try write(file)
            return pairing
        }
        file.pairings[index] = pairing
        try write(file)
        return nil
    }

    func markCredentialUnusable(pairingID: UUID) throws {
        var file = try readFile()
        guard let index = file.pairings.firstIndex(where: { $0.id == pairingID }) else { return }
        file.pairings[index].credentialUsable = false
        try write(file)
    }

    func recordFirstReadyRoute(_ identity: HomeRouteIdentity, for profileID: UUID) throws {
        var file = try readFile()
        guard let index = file.pairings.firstIndex(where: { $0.grantID(for: profileID) != nil }) else {
            throw HomeClientPairingStoreError.unknownPairing
        }
        guard identity.routeClass == .home, identity.isValid else {
            throw HomeClientPairingStoreError.routeIdentityMismatch
        }
        if let pinned = file.pairings[index].pinnedRouteID {
            guard pinned == identity.id else { throw HomeClientPairingStoreError.routeIdentityMismatch }
            return
        }
        file.pairings[index].pinnedRouteID = identity.id
        try write(file)
    }

    func approvedRoute(for profileID: UUID) throws -> HomeApprovedRoute? {
        try pairing(forProfile: profileID)?.approvedRoute
    }

    private func readFile() throws -> HomeClientPairingFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let file: HomeClientPairingFile
        do {
            file = try JSONDecoder().decode(HomeClientPairingFile.self, from: Data(contentsOf: fileURL))
        } catch {
            throw HomeClientPairingStoreError.invalidStorage
        }
        guard file.schemaVersion == HomeClientPairing.currentSchemaVersion else {
            throw HomeClientPairingStoreError.unsupportedSchema
        }
        return file
    }

    private func write(_ file: HomeClientPairingFile) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(file).write(to: fileURL, options: .atomic)
    }
}

/// Paired profiles resolve their route from the pairing record; every other
/// profile keeps the operator-provisioned route.
struct AppHomeApprovedRouteProvider: HomeApprovedRouteProvider {
    let pairings: JSONHomeClientPairingStore
    let legacy: (any HomeApprovedRouteProvider)?

    func approvedRoute(for profileID: UUID) async throws -> HomeApprovedRoute? {
        // An unreadable pairing file is "not paired": operator-provisioned
        // profiles keep working, and a paired profile fails closed.
        if let pairing = try? await pairings.pairing(forProfile: profileID) {
            return pairing.approvedRoute
        }
        return try await legacy?.approvedRoute(for: profileID)
    }
}

/// Resolves a paired profile to its pairing's Keychain credential. A profile
/// without a pairing keeps its legacy per-profile account unchanged.
struct PairingAwareHomeCredentialStore: HomeCredentialStore {
    let pairings: JSONHomeClientPairingStore
    let credentials: any HomeCredentialProvisioningStore

    private func owner(for profileID: UUID) async throws -> UUID {
        // An unreadable pairing file is "not paired" (see the route provider).
        (try? await pairings.pairing(forProfile: profileID))?.id ?? profileID
    }

    func stage(preIssued: HomeCredentialReference, for profileID: UUID) async throws {
        try await credentials.stage(preIssued: preIssued, for: owner(for: profileID))
    }

    func verifiedReadBack(for profileID: UUID) async throws -> HomeCredentialRecord {
        try await credentials.verifiedReadBack(for: owner(for: profileID))
    }

    func withPrivateDeviceCredential(
        for profileID: UUID,
        _ body: @Sendable (Data) async throws -> Void
    ) async throws {
        try await credentials.withPrivateDeviceCredential(for: owner(for: profileID), body)
    }

    func commitHomeSelection(for profileID: UUID) async throws {
        try await credentials.commitHomeSelection(for: owner(for: profileID))
    }

    func rollbackToLegacyAtIdle(for profileID: UUID) async throws {
        try await credentials.rollbackToLegacyAtIdle(for: owner(for: profileID))
    }
}

// MARK: - Claim per connect

enum HomeClientConnectError: Error, LocalizedError, Equatable, Sendable {
    case pairAgain(home: String)
    case denied(HomeClientDenial)
    case homeUnreachable
    case invalidResponse
    case credentialUnavailable

    var errorDescription: String? {
        switch self {
        case .pairAgain(let home):
            return "Pair again with \(home)."
        case .denied(let denial):
            switch denial {
            case .grantPending:
                return "This Profile is waiting for its owner to approve it on Home."
            case .profileUnavailable:
                return "This Hermes Profile is unavailable on Home right now."
            case .clientClaimUnavailable:
                return "Home no longer grants this device access to this Profile."
            case .claimLimit:
                return "This device has too many open Home conversations. Disconnect one or wait a few minutes, then connect again."
            case .staleConfiguration:
                return "Home configuration changed while connecting. Connect again."
            case .configurationMigrationRequired:
                return "Home configuration needs an administrator update before this Profile can connect."
            case .serviceUnavailable:
                return "Home cannot accept conversations right now. Connect again later."
            default:
                return "Home did not grant a conversation (\(denial.rawValue))."
            }
        case .homeUnreachable:
            return "Home is unreachable. Connect again when it is available."
        case .invalidResponse:
            return "Home returned an unexpected response."
        case .credentialUnavailable:
            return "The Home credential could not be read from Keychain. Unlock this device and connect again."
        }
    }

    var failure: HomeBridgeFailure {
        switch self {
        case .pairAgain:
            return .home(code: .unauthorized, phase: .authorization)
        case .denied:
            return .home(code: .authorizationUnavailable, phase: .authorization)
        case .homeUnreachable:
            return .home(code: .transportUnavailable, phase: .authorization)
        case .invalidResponse:
            return .home(code: .protocolError, phase: .authorization)
        case .credentialUnavailable:
            return .home(code: .authorizationUnavailable, phase: .authorization)
        }
    }
}

private final class HomeClientResultBox<Value>: @unchecked Sendable {
    var value: Value?
}

/// Renews when due, reads the configuration revision, and makes one fresh
/// `session: new` client claim per connect. Claims are single-use and expire
/// shortly after issue, so none is ever cached here.
actor HomeClientClaimCoordinator {
    private let service: any HomeClientService
    private let pairings: JSONHomeClientPairingStore
    private let credentials: any HomeCredentialProvisioningStore
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String

    init(
        service: any HomeClientService,
        pairings: JSONHomeClientPairingStore,
        credentials: any HomeCredentialProvisioningStore,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.service = service
        self.pairings = pairings
        self.credentials = credentials
        self.now = now
        self.makeID = makeID
    }

    func isPaired(profileID: UUID) async -> Bool {
        (try? await pairings.pairing(forProfile: profileID)) != nil
    }

    /// Nil when the profile is not paired, so callers fall through to the
    /// operator-provisioned claim.
    func claim(for profileID: UUID) async throws -> HomeConversationClaim? {
        // An unreadable pairing file is "not paired", so operator-provisioned
        // profiles fall through unchanged.
        guard let paired = try? await pairings.pairing(forProfile: profileID),
              let grantID = paired.grantID(for: profileID) else {
            return nil
        }
        var pairing = paired
        do {
            guard pairing.credentialUsable else {
                throw HomeClientConnectError.pairAgain(home: pairing.home.displayName)
            }
            // Home closes live claims on renewal, so renew before claiming.
            pairing = try await renewIfDue(pairing)
            var configuration = try await readConfiguration(&pairing)
            var refreshedAfterStale = false
            while true {
                let request = HomeClientClaimRequest(
                    claimID: "client-\(makeID())",
                    deviceID: pairing.deviceID,
                    configurationRevision: configuration.revision,
                    grantID: grantID
                )
                do {
                    let home = pairing.home
                    let grant = try await withCredential(pairing) { [service] credential in
                        try await service.claimConversation(home: home, credential: credential, request)
                    }
                    return HomeConversationClaim(
                        profileID: profileID,
                        conversationHandle: grant.conversationHandle,
                        approvedRoute: pairing.approvedRoute,
                        routePinPending: pairing.pinnedRouteID == nil
                    )
                } catch HomeClientServiceError.denied(.staleConfiguration) where !refreshedAfterStale {
                    refreshedAfterStale = true
                    configuration = try await readConfiguration(&pairing)
                }
            }
        } catch {
            throw await connectError(error, pairing: pairing)
        }
    }

    /// Renews if due, then reads grants and revision into the pairing record.
    func refreshConfiguration(pairingID: UUID) async throws -> HomeClientPairing {
        guard var pairing = try await pairings.pairing(id: pairingID) else {
            throw HomeClientPairingStoreError.unknownPairing
        }
        do {
            guard pairing.credentialUsable else {
                throw HomeClientConnectError.pairAgain(home: pairing.home.displayName)
            }
            pairing = try await renewIfDue(pairing)
            _ = try await readConfiguration(&pairing)
            return pairing
        } catch {
            throw await connectError(error, pairing: pairing)
        }
    }

    func renewIfDue(_ pairing: HomeClientPairing) async throws -> HomeClientPairing {
        var pairing = pairing
        if let pendingRequestID = pairing.pendingRenewalRequestID {
            // A renewal was interrupted. If Keychain already holds the new
            // credential, finish the record; otherwise repeat the same
            // idempotent request.
            if let record = try? await credentials.verifiedReadBack(for: pairing.id),
               record.reference.expiresAt > pairing.credentialExpiresAt {
                let expected = pairing.generation
                return try await pairings.update(pairingID: pairing.id) { current in
                    guard current.pendingRenewalRequestID == pendingRequestID else { return }
                    current.generation = max(current.generation, expected + 1)
                    current.credentialExpiresAt = max(current.credentialExpiresAt, record.reference.expiresAt)
                    current.pendingRenewalRequestID = nil
                }
            }
            return try await performRenewal(pairing, requestID: pendingRequestID)
        }
        let date = now()
        if date >= pairing.credentialExpiresAt {
            throw HomeClientConnectError.pairAgain(home: pairing.home.displayName)
        }
        guard pairing.credentialReference.isRenewalEligible(at: date) else { return pairing }
        let requestID = "renew-\(makeID())"
        pairing = try await pairings.update(pairingID: pairing.id) {
            $0.pendingRenewalRequestID = requestID
        }
        return try await performRenewal(pairing, requestID: requestID)
    }

    private func performRenewal(
        _ pairing: HomeClientPairing,
        requestID: String
    ) async throws -> HomeClientPairing {
        let material: HomeCredentialMaterial
        do {
            let home = pairing.home
            let deviceID = pairing.deviceID
            let generation = pairing.generation
            material = try await withCredential(pairing) { [service] credential in
                try await service.renewCredential(
                    home: home,
                    deviceID: deviceID,
                    credential: credential,
                    requestID: requestID,
                    generation: generation
                )
            }
        } catch HomeClientServiceError.denied(.conflict) {
            // Home's clock says renewal is not due, or the request was already
            // settled. The current credential stays in use.
            return try await pairings.update(pairingID: pairing.id) {
                if $0.pendingRenewalRequestID == requestID { $0.pendingRenewalRequestID = nil }
            }
        } catch HomeClientServiceError.denied(.expiredOrConsumed) {
            throw HomeClientConnectError.pairAgain(home: pairing.home.displayName)
        }
        guard material.deviceID == pairing.deviceID, material.generation > pairing.generation else {
            throw HomeClientConnectError.invalidResponse
        }
        let expiresAt = HomeClientPairing.normalizedExpiry(material.expiresAt)
        try await credentials.provision(
            preIssuedCredential: material.credential,
            reference: HomeClientPairing.credentialReference(pairingID: pairing.id, expiresAt: expiresAt),
            for: pairing.id
        )
        return try await pairings.update(pairingID: pairing.id) {
            $0.generation = material.generation
            $0.credentialExpiresAt = expiresAt
            $0.pendingRenewalRequestID = nil
        }
    }

    private func readConfiguration(
        _ pairing: inout HomeClientPairing
    ) async throws -> HomeClientDeviceConfiguration {
        let home = pairing.home
        let deviceID = pairing.deviceID
        let configuration = try await withCredential(pairing) { [service] credential in
            try await service.deviceConfiguration(home: home, deviceID: deviceID, credential: credential)
        }
        let grants = configuration.clientGrants
        pairing = try await pairings.update(pairingID: pairing.id) { $0.grants = grants }
        return configuration
    }

    private func withCredential<Value: Sendable>(
        _ pairing: HomeClientPairing,
        _ body: @escaping @Sendable (Data) async throws -> Value
    ) async throws -> Value {
        let box = HomeClientResultBox<Value>()
        do {
            try await credentials.withPrivateDeviceCredential(for: pairing.id) { credential in
                box.value = try await body(credential)
            }
        } catch let error as HomeCredentialStoreError {
            switch error {
            case .missingCredential, .emptyCredential, .invalidReference:
                throw HomeClientConnectError.pairAgain(home: pairing.home.displayName)
            case .unusableState:
                throw HomeClientConnectError.credentialUnavailable
            }
        } catch let error as HomeCredentialReferenceError {
            _ = error
            throw HomeClientConnectError.pairAgain(home: pairing.home.displayName)
        }
        guard let value = box.value else { throw HomeClientConnectError.invalidResponse }
        return value
    }

    private func connectError(_ error: Error, pairing: HomeClientPairing) async -> Error {
        let mapped: HomeClientConnectError
        switch error {
        case let error as HomeClientConnectError:
            mapped = error
        case HomeClientServiceError.denied(.unauthorized):
            mapped = .pairAgain(home: pairing.home.displayName)
        case HomeClientServiceError.denied(let denial):
            mapped = .denied(denial)
        case HomeClientServiceError.transportUnavailable, HomeClientServiceError.unexpectedStatus:
            mapped = .homeUnreachable
        case is CancellationError:
            return error
        case is HomeClientServiceError:
            mapped = .invalidResponse
        default:
            // Keychain or file-system failures.
            mapped = .credentialUnavailable
        }
        if case .pairAgain = mapped {
            try? await pairings.markCredentialUnusable(pairingID: pairing.id)
        }
        return mapped
    }
}

// MARK: - Pairing flow

enum HomePairingFlowError: Error, LocalizedError, Equatable, Sendable {
    case codeNotAccepted
    case rejected
    case expired
    case expiredOrConsumed
    case homeUnreachable
    case notAPersonalClientCredential
    case keychainFailure
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .codeNotAccepted:
            return "Home did not accept this pairing code. It may have expired; open a new one on the Home pairing page."
        case .rejected:
            return "The pairing request was rejected on the Home page. Start again to pair."
        case .expired:
            return "The pairing request expired before it was approved. Start again to pair."
        case .expiredOrConsumed:
            return "The pairing request expired or was already used. If this device now appears on the Home page, remove it there, then pair again."
        case .homeUnreachable:
            return "Home is unreachable. Check the address and your connection, then start again."
        case .notAPersonalClientCredential:
            return "Home approved this device without conversation access. Start again and approve it as a personal client."
        case .keychainFailure:
            return "The Home credential could not be saved to Keychain, so the pairing was not saved. Start again."
        case .invalidResponse:
            return "Home returned an unexpected response. Start again."
        }
    }

    var canStartAgain: Bool { true }
}

struct HomeClientPairingSummary: Equatable, Sendable {
    struct Grant: Equatable, Sendable, Identifiable {
        let grantID: String
        let label: String
        let status: HomeClientGrantStatus
        let available: Bool
        let profileName: String?

        var id: String { grantID }
        var isWaitingForOwner: Bool { status == .pendingOwner }
    }

    let pairingID: UUID
    let homeName: String
    let grants: [Grant]
    let routePinned: Bool
    let credentialUsable: Bool
    /// Set when the first live `ready` could not be proven; Home mode is not
    /// selected until it is.
    let activationFailure: String?
}

/// submit → poll consume → Keychain provision → save pairing → one profile
/// per active grant → first live `ready` (route pin) → journal `homeSelected`.
actor HomeClientPairingCoordinator {
    static let pollInterval: Duration = .seconds(2)

    private let service: any HomeClientService
    private let pairings: JSONHomeClientPairingStore
    private let credentials: any HomeCredentialProvisioningStore
    private let configurationStore: RelayConfigurationStore
    private let claimCoordinator: HomeClientClaimCoordinator
    private let homeClientFactory: any HomeBridgeSessionClientFactory
    private let identity: RelayDeviceIdentity
    private let endpointType: HomeClientEndpointType
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        service: any HomeClientService,
        pairings: JSONHomeClientPairingStore,
        credentials: any HomeCredentialProvisioningStore,
        configurationStore: RelayConfigurationStore,
        claimCoordinator: HomeClientClaimCoordinator,
        homeClientFactory: any HomeBridgeSessionClientFactory,
        identity: RelayDeviceIdentity,
        endpointType: HomeClientEndpointType = .current,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.pairings = pairings
        self.credentials = credentials
        self.configurationStore = configurationStore
        self.claimCoordinator = claimCoordinator
        self.homeClientFactory = homeClientFactory
        self.identity = identity
        self.endpointType = endpointType
        self.now = now
        self.sleep = sleep
    }

    func submit(_ invitation: HomePairingInvitation) async throws -> HomeEnrollmentPendingRequest {
        let endpointID = try await pairings.endpointID(for: invitation.home)
        let submission = HomeEnrollmentSubmission(
            enrollmentCode: invitation.code,
            endpointID: endpointID,
            label: identity.displayName,
            type: endpointType
        )
        do {
            return try await service.submitEnrollment(home: invitation.home, submission)
        } catch {
            throw Self.flowError(error)
        }
    }

    /// Polls consume about every two seconds until approval, rejection, or
    /// `expires_at`. Cancelling the task stops polling; nothing is stored
    /// until approval.
    func awaitApproval(
        _ invitation: HomePairingInvitation,
        request: HomeEnrollmentPendingRequest
    ) async throws -> HomeCredentialMaterial {
        while true {
            try Task.checkCancellation()
            guard now() < request.expiresAt else { throw HomePairingFlowError.expired }
            do {
                return try await service.consumeEnrollment(
                    home: invitation.home,
                    requestID: request.requestID,
                    enrollmentCode: invitation.code
                )
            } catch HomeClientServiceError.denied(.approvalPending) {
                // Keep waiting for the Home page.
            } catch HomeClientServiceError.transportUnavailable {
                // A brief outage while waiting is not a terminal answer.
            } catch {
                throw Self.flowError(error)
            }
            try await sleep(Self.pollInterval)
        }
    }

    /// Waits for approval and completes the pairing without handing the
    /// credential material to the caller.
    func finishPairing(
        _ invitation: HomePairingInvitation,
        request: HomeEnrollmentPendingRequest
    ) async throws -> HomeClientPairingSummary {
        let material = try await awaitApproval(invitation, request: request)
        return try await complete(invitation, material: material)
    }

    func complete(
        _ invitation: HomePairingInvitation,
        material: HomeCredentialMaterial
    ) async throws -> HomeClientPairingSummary {
        guard material.capabilities.contains("client_claim") else {
            throw HomePairingFlowError.notAPersonalClientCredential
        }
        let existing = try await pairings.pairing(forHome: invitation.home)
        let pairingID = existing?.id ?? UUID()
        let endpointID = try await pairings.endpointID(for: invitation.home)
        let expiresAt = HomeClientPairing.normalizedExpiry(material.expiresAt)
        let reference = HomeClientPairing.credentialReference(pairingID: pairingID, expiresAt: expiresAt)
        do {
            try await credentials.provision(
                preIssuedCredential: material.credential,
                reference: reference,
                for: pairingID
            )
            let readBack = try await credentials.verifiedReadBack(for: pairingID)
            guard readBack.reference == reference else { throw HomePairingFlowError.keychainFailure }
        } catch {
            throw HomePairingFlowError.keychainFailure
        }

        // Pairing again keeps each existing profile (and its transcript) for
        // a grant with the same ID or, failing that, the same label.
        var profiles: [HomeClientPairedProfile] = []
        for grant in material.clientGrants {
            guard let existing else { break }
            if let profileID = existing.profileID(for: grant.grantID) {
                profiles.append(HomeClientPairedProfile(profileID: profileID, grantID: grant.grantID))
            } else if let previous = existing.grants.first(where: { $0.label == grant.label }),
                      let profileID = existing.profileID(for: previous.grantID),
                      !profiles.contains(where: { $0.profileID == profileID }) {
                profiles.append(HomeClientPairedProfile(profileID: profileID, grantID: grant.grantID))
            }
        }
        var pairing = HomeClientPairing(
            id: pairingID,
            home: invitation.home,
            endpointID: endpointID,
            deviceID: material.deviceID,
            generation: material.generation,
            credentialExpiresAt: expiresAt,
            grants: material.clientGrants,
            profiles: profiles
        )
        try await pairings.save(pairing)
        pairing = try await ensureProfiles(pairing)
        return try await activate(pairing, selectActivatedProfile: true)
    }

    /// Re-reads grants (renewing first when due). A grant that became active
    /// gains its own profile.
    func refresh(pairingID: UUID) async throws -> HomeClientPairingSummary {
        var pairing = try await claimCoordinator.refreshConfiguration(pairingID: pairingID)
        pairing = try await ensureProfiles(pairing)
        return try await activate(pairing, selectActivatedProfile: false)
    }

    func summary(pairingID: UUID) async throws -> HomeClientPairingSummary {
        guard let pairing = try await pairings.pairing(id: pairingID) else {
            throw HomeClientPairingStoreError.unknownPairing
        }
        return try await makeSummary(pairing, activationFailure: nil)
    }

    func allPairings() async throws -> [HomeClientPairing] {
        try await pairings.pairings()
    }

    /// Removing a paired profile unbinds its grant; the last one removes the
    /// Keychain credential and the pairing record.
    func profileRemoved(_ profileID: UUID) async throws {
        guard let emptied = try await pairings.removeProfile(profileID) else { return }
        try await credentials.removeCredential(for: emptied.id)
    }

    private func ensureProfiles(_ pairing: HomeClientPairing) async throws -> HomeClientPairing {
        var pairing = try await pairings.pairing(id: pairing.id) ?? pairing
        let collection = try await configurationStore.loadCollection()
        for grant in pairing.grants where grant.isActive
            && !pairing.unboundGrantIDs.contains(grant.grantID) {
            let profileID: UUID
            if let mapped = pairing.profileID(for: grant.grantID) {
                guard !collection.profiles.contains(where: { $0.id == mapped }) else { continue }
                profileID = mapped
            } else {
                // Record the mapping first; a crash before the profile is
                // written is repaired by the next refresh.
                let minted = UUID()
                pairing = try await pairings.update(pairingID: pairing.id) { current in
                    if !current.profiles.contains(where: { $0.grantID == grant.grantID }) {
                        current.profiles.append(HomeClientPairedProfile(profileID: minted, grantID: grant.grantID))
                    }
                }
                guard let recorded = pairing.profileID(for: grant.grantID) else { continue }
                profileID = recorded
            }
            let profile = try RelayProfile(
                id: profileID,
                endpoint: pairing.home.bridgeEndpoint,
                clientID: identity.clientID,
                deviceID: identity.deviceID,
                displayName: HomeClientPairing.profileDisplayName(grantLabel: grant.label, home: pairing.home)
            )
            try await configurationStore.saveProfile(profile)
        }
        return pairing
    }

    /// Proves one live `ready` (pinning the route) before any paired profile
    /// selects Home. Once pinned, newly granted profiles select Home directly.
    private func activate(
        _ pairing: HomeClientPairing,
        selectActivatedProfile: Bool
    ) async throws -> HomeClientPairingSummary {
        // Available grants first, so an unavailable Profile never blocks a
        // usable one from proving the pairing.
        let activeGrants = pairing.grants.filter(\.isActive)
        let activeProfiles = (activeGrants.filter(\.available) + activeGrants.filter { !$0.available })
            .compactMap { pairing.profileID(for: $0.grantID) }
        guard var selectedProfile = activeProfiles.first else {
            return try await makeSummary(pairing, activationFailure: nil)
        }
        var current = pairing
        if current.pinnedRouteID == nil {
            var lastFailure: String?
            var proven: UUID?
            for profileID in activeProfiles {
                if let failure = await proveLiveReady(profileID: profileID) {
                    lastFailure = failure
                    continue
                }
                proven = profileID
                break
            }
            guard let proven else {
                return try await makeSummary(current, activationFailure: lastFailure)
            }
            guard let refreshed = try await pairings.pairing(id: pairing.id),
                  refreshed.pinnedRouteID != nil else {
                return try await makeSummary(
                    current,
                    activationFailure: HomeClientPairingStoreError.routeIdentityMismatch.localizedDescription
                )
            }
            selectedProfile = proven
            current = refreshed
        }
        for profileID in activeProfiles {
            try await configurationStore.selectPairedHome(for: profileID)
        }
        if selectActivatedProfile {
            try await configurationStore.selectProfile(id: selectedProfile)
        }
        return try await makeSummary(current, activationFailure: nil)
    }

    /// Nil on success; otherwise a safe message.
    private func proveLiveReady(profileID: UUID) async -> String? {
        let claim: HomeConversationClaim
        do {
            guard let made = try await claimCoordinator.claim(for: profileID) else {
                return HomeClientPairingStoreError.unknownPairing.localizedDescription
            }
            claim = made
        } catch {
            return error.localizedDescription
        }
        let client = homeClientFactory.make(profileID: profileID, mode: .home)
        let outcome = await client.open(claim: claim)
        guard case .ready(let binding, _) = outcome else {
            await client.close()
            switch outcome {
            case .unavailable(let failure), .disconnected(let failure):
                return "Home did not complete the first connection (\(failure.safeReason)). Try again."
            case .ready:
                return nil
            }
        }
        // The proof claim is not the user's conversation; end it now rather
        // than holding a claim slot through the reconnect grace.
        _ = await client.close(binding: binding)
        await client.close()
        return nil
    }

    private func makeSummary(
        _ pairing: HomeClientPairing,
        activationFailure: String?
    ) async throws -> HomeClientPairingSummary {
        let collection = try await configurationStore.loadCollection()
        return HomeClientPairingSummary(
            pairingID: pairing.id,
            homeName: pairing.home.displayName,
            grants: pairing.grants.map { grant in
                let profileName = pairing.profileID(for: grant.grantID).flatMap { id in
                    collection.profiles.first { $0.id == id }?.displayName
                }
                return HomeClientPairingSummary.Grant(
                    grantID: grant.grantID,
                    label: grant.label,
                    status: grant.status,
                    available: grant.available,
                    profileName: profileName
                )
            },
            routePinned: pairing.pinnedRouteID != nil,
            credentialUsable: pairing.credentialUsable,
            activationFailure: activationFailure
        )
    }

    private static func flowError(_ error: Error) -> Error {
        switch error {
        case let error as HomePairingFlowError:
            return error
        case is CancellationError:
            return error
        case HomeClientServiceError.denied(.rejected):
            return HomePairingFlowError.rejected
        case HomeClientServiceError.denied(.expiredOrConsumed):
            // Home also answers this for a request already consumed, for
            // example when the consume response was lost.
            return HomePairingFlowError.expiredOrConsumed
        case HomeClientServiceError.denied(.unauthorized),
             HomeClientServiceError.denied(.notFound),
             HomeClientServiceError.denied(.invalidRequest):
            return HomePairingFlowError.codeNotAccepted
        case HomeClientServiceError.transportUnavailable,
             HomeClientServiceError.unexpectedStatus,
             HomeClientServiceError.denied(.serviceUnavailable):
            return HomePairingFlowError.homeUnreachable
        default:
            return HomePairingFlowError.invalidResponse
        }
    }
}
