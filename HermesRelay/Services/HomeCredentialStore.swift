import Foundation

/// Home administration is a separate trust boundary from relay tokens and
/// per-Device credentials. Keep its bearer in its own profile-scoped record.
enum HomeAdminCredentialKeychain {
    static let service = "com.achappell.HermesRelayIOS.home-admin"

    static func account(for profileID: UUID) -> String {
        "admin-credential.\(profileID.uuidString)"
    }
}

enum HomeAdminCredentialStoreError: Error, LocalizedError, Equatable, Sendable {
    case emptyCredential
    case invalidApprovedRoute
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case .emptyCredential:
            "The Home admin credential cannot be empty."
        case .invalidApprovedRoute:
            "The approved Home route is invalid. Re-approve the route before managing Devices."
        case .invalidEncoding:
            "The stored Home admin credential is invalid. Re-enter it in Configure Relay."
        }
    }
}

protocol HomeAdminCredentialStore: Sendable {
    func load(
        for profileID: UUID,
        approvedRoute: HomeApprovedRoute
    ) async throws -> String?
    func hasCredential(
        for profileID: UUID,
        approvedRoute: HomeApprovedRoute
    ) async -> Bool
    func save(
        _ credential: String,
        for profileID: UUID,
        approvedRoute: HomeApprovedRoute
    ) async throws
    func delete(for profileID: UUID) async throws
}

enum HomeAdminCredentialFormSaveResult: Equatable, Sendable {
    case stored
    case preserved
}

/// The form treats an empty Save differently from Remove. Keep that decision
/// in one seam so the UI cannot accidentally clear a secret when its field is
/// blank or a route has just changed.
struct HomeAdminCredentialFormActions: Sendable {
    private let store: any HomeAdminCredentialStore

    init(store: any HomeAdminCredentialStore) {
        self.store = store
    }

    func save(
        _ credential: String,
        for profileID: UUID,
        approvedRoute: HomeApprovedRoute
    ) async throws -> HomeAdminCredentialFormSaveResult {
        let normalized = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            guard await store.hasCredential(
                for: profileID,
                approvedRoute: approvedRoute
            ) else {
                throw HomeAdminCredentialStoreError.emptyCredential
            }
            return .preserved
        }

        try await store.save(
            normalized,
            for: profileID,
            approvedRoute: approvedRoute
        )
        return .stored
    }

    func remove(for profileID: UUID) async throws {
        try await store.delete(for: profileID)
    }
}

/// The Home admin bearer is stored in a dedicated Keychain item together
/// with the full non-secret approved route. Any endpoint, route identity, or
/// household change therefore requires the operator to bind it again.
struct HomeAdminCredentialKeychainRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let profileID: UUID
    /// Optional so old v1 records decode but cannot be used for a route that
    /// they were never bound to. The operator must re-enter that credential.
    let approvedRoute: HomeApprovedRoute?
    let credential: String

    init(
        profileID: UUID,
        approvedRoute: HomeApprovedRoute,
        credential: String,
        schemaVersion: Int = HomeAdminCredentialKeychainRecord.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.approvedRoute = approvedRoute
        self.credential = credential
    }
}

actor KeychainHomeAdminCredentialStore: HomeAdminCredentialStore {
    private let secureStore: any SecureValueStore

    init(secureStore: any SecureValueStore) {
        self.secureStore = secureStore
    }

    func load(
        for profileID: UUID,
        approvedRoute: HomeApprovedRoute
    ) async throws -> String? {
        try validateApprovedRoute(approvedRoute)
        guard let value = try secureStore.read(
            service: HomeAdminCredentialKeychain.service,
            account: HomeAdminCredentialKeychain.account(for: profileID)
        ) else {
            return nil
        }
        let record: HomeAdminCredentialKeychainRecord
        do {
            record = try JSONDecoder().decode(
                HomeAdminCredentialKeychainRecord.self,
                from: value
            )
        } catch {
            throw HomeAdminCredentialStoreError.invalidEncoding
        }
        guard record.schemaVersion == HomeAdminCredentialKeychainRecord.currentSchemaVersion,
              record.profileID == profileID,
              record.approvedRoute == approvedRoute else {
            return nil
        }
        let normalized = record.credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw HomeAdminCredentialStoreError.emptyCredential
        }
        return normalized
    }

    func hasCredential(
        for profileID: UUID,
        approvedRoute: HomeApprovedRoute
    ) async -> Bool {
        (try? await load(for: profileID, approvedRoute: approvedRoute)) != nil
    }

    func save(
        _ credential: String,
        for profileID: UUID,
        approvedRoute: HomeApprovedRoute
    ) async throws {
        try validateApprovedRoute(approvedRoute)
        let normalized = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw HomeAdminCredentialStoreError.emptyCredential
        }
        let record = HomeAdminCredentialKeychainRecord(
            profileID: profileID,
            approvedRoute: approvedRoute,
            credential: normalized
        )
        try secureStore.write(
            try JSONEncoder().encode(record),
            service: HomeAdminCredentialKeychain.service,
            account: HomeAdminCredentialKeychain.account(for: profileID)
        )
    }

    func delete(for profileID: UUID) async throws {
        try secureStore.delete(
            service: HomeAdminCredentialKeychain.service,
            account: HomeAdminCredentialKeychain.account(for: profileID)
        )
    }

    private func validateApprovedRoute(_ approvedRoute: HomeApprovedRoute) throws {
        do {
            try approvedRoute.validate()
        } catch {
            throw HomeAdminCredentialStoreError.invalidApprovedRoute
        }
    }
}

enum HomeCredentialStoreError: Error, Equatable, Sendable {
    case missingCredential
    case emptyCredential
    case invalidReference
    case unusableState(HomeCredentialState)
}

/// The one-time operator handoff used by the live Home setup surface. The
/// credential is accepted as Data only long enough to write it to Keychain;
/// no caller receives it back from this API.
protocol HomeCredentialProvisioningStore: HomeCredentialStore {
    func provision(
        preIssuedCredential: Data,
        reference: HomeCredentialReference,
        for profileID: UUID
    ) async throws

    /// Deletes the secret and its reference. Used when a Home pairing's last
    /// profile is removed.
    func removeCredential(for ownerID: UUID) async throws
}

/// The reference metadata and the pre-issued value live in separate secure
/// records. The public API never returns the value; it exists only for the
/// duration of the private accessor closure.
actor KeychainHomeCredentialStore: HomeCredentialProvisioningStore {
    private let secureStore: any SecureValueStore
    private var states: [UUID: HomeCredentialState] = [:]

    init(secureStore: any SecureValueStore) {
        self.secureStore = secureStore
    }

    func provision(
        preIssuedCredential: Data,
        reference: HomeCredentialReference,
        for profileID: UUID
    ) async throws {
        try reference.validate(for: profileID)
        guard !preIssuedCredential.isEmpty else {
            throw HomeCredentialStoreError.emptyCredential
        }
        try secureStore.write(
            preIssuedCredential,
            service: reference.service,
            account: reference.account
        )
        try await stage(preIssued: reference, for: profileID)
    }

    func stage(preIssued: HomeCredentialReference, for profileID: UUID) async throws {
        try preIssued.validate(for: profileID)
        guard secureStoreValueExists(preIssued) else {
            throw HomeCredentialStoreError.missingCredential
        }
        try secureStore.write(
            try JSONEncoder().encode(preIssued),
            service: HomeCredentialKeychain.service,
            account: Self.metadataAccount(for: profileID)
        )
        states[profileID] = .active
    }

    func verifiedReadBack(for profileID: UUID) async throws -> HomeCredentialRecord {
        guard let reference = try reference(for: profileID) else {
            throw HomeCredentialStoreError.missingCredential
        }
        try reference.validate(for: profileID)
        guard secureStoreValueExists(reference) else {
            throw HomeCredentialStoreError.missingCredential
        }
        let state = states[profileID] ?? .active
        guard state == .active else { throw HomeCredentialStoreError.unusableState(state) }
        return HomeCredentialRecord(profileID: profileID, reference: reference, state: state)
    }

    func withPrivateDeviceCredential(
        for profileID: UUID,
        _ body: @Sendable (Data) async throws -> Void
    ) async throws {
        let record = try await verifiedReadBack(for: profileID)
        guard let value = try secureStore.read(
            service: record.reference.service,
            account: record.reference.account
        ) else {
            throw HomeCredentialStoreError.missingCredential
        }
        try await body(value)
    }

    func commitHomeSelection(for profileID: UUID) async throws {
        _ = try await verifiedReadBack(for: profileID)
    }

    func rollbackToLegacyAtIdle(for profileID: UUID) async throws {
        guard let record = try? await verifiedReadBack(for: profileID) else { return }
        _ = record
        states[profileID] = .active
    }

    func removeCredential(for ownerID: UUID) async throws {
        let valueAccount = (try? reference(for: ownerID))?.account
            ?? HomeCredentialKeychain.account(forPairing: ownerID)
        try secureStore.delete(service: HomeCredentialKeychain.service, account: valueAccount)
        try secureStore.delete(
            service: HomeCredentialKeychain.service,
            account: Self.metadataAccount(for: ownerID)
        )
        states.removeValue(forKey: ownerID)
    }

    func setState(_ state: HomeCredentialState, for profileID: UUID) {
        states[profileID] = state
    }

    func state(for profileID: UUID) -> HomeCredentialState? {
        states[profileID]
    }

    private func reference(for profileID: UUID) throws -> HomeCredentialReference? {
        let metadataAccount = Self.metadataAccount(for: profileID)
        guard let data = try secureStore.read(
            service: HomeCredentialKeychain.service,
            account: metadataAccount
        ) else { return nil }
        return try JSONDecoder().decode(HomeCredentialReference.self, from: data)
    }

    private func secureStoreValueExists(_ reference: HomeCredentialReference) -> Bool {
        do {
            return try secureStore.read(
                service: reference.service,
                account: reference.account
            ) != nil
        } catch {
            return false
        }
    }

    private static func metadataAccount(for profileID: UUID) -> String {
        "reference.\(profileID.uuidString)"
    }
}

/// A deterministic secure-store implementation for Home migration tests and
/// the Debug fake. It records metadata and compares values internally without
/// exposing them through a migration result.
actor InMemoryHomeCredentialStore: HomeCredentialProvisioningStore {
    private var values: [String: Data]
    private var references: [UUID: HomeCredentialReference] = [:]
    private var states: [UUID: HomeCredentialState] = [:]

    init(
        secureValue: Data? = nil,
        reference: HomeCredentialReference? = nil,
        profileID: UUID? = nil
    ) {
        var values: [String: Data] = [:]
        if let secureValue, let reference {
            values[Self.key(reference)] = secureValue
        }
        self.values = values
        if let profileID, let reference {
            references[profileID] = reference
        }
    }

    func seed(
        credential: Data,
        reference: HomeCredentialReference,
        for profileID: UUID
    ) {
        values[Self.key(reference)] = credential
        references[profileID] = reference
        states[profileID] = .active
    }

    func provision(
        preIssuedCredential: Data,
        reference: HomeCredentialReference,
        for profileID: UUID
    ) async throws {
        try reference.validate(for: profileID)
        guard !preIssuedCredential.isEmpty else {
            throw HomeCredentialStoreError.emptyCredential
        }
        values[Self.key(reference)] = preIssuedCredential
        try await stage(preIssued: reference, for: profileID)
    }

    func stage(preIssued: HomeCredentialReference, for profileID: UUID) async throws {
        try preIssued.validate(for: profileID)
        guard values[Self.key(preIssued)] != nil else {
            throw HomeCredentialStoreError.missingCredential
        }
        references[profileID] = preIssued
        states[profileID] = .active
    }

    func verifiedReadBack(for profileID: UUID) async throws -> HomeCredentialRecord {
        guard let reference = references[profileID] else {
            throw HomeCredentialStoreError.missingCredential
        }
        try reference.validate(for: profileID)
        guard values[Self.key(reference)] != nil else {
            throw HomeCredentialStoreError.missingCredential
        }
        let state = states[profileID] ?? .active
        guard state == .active else { throw HomeCredentialStoreError.unusableState(state) }
        return HomeCredentialRecord(profileID: profileID, reference: reference, state: state)
    }

    func withPrivateDeviceCredential(
        for profileID: UUID,
        _ body: @Sendable (Data) async throws -> Void
    ) async throws {
        let record = try await verifiedReadBack(for: profileID)
        guard let value = values[Self.key(record.reference)] else {
            throw HomeCredentialStoreError.missingCredential
        }
        try await body(value)
    }

    func commitHomeSelection(for profileID: UUID) async throws {
        _ = try await verifiedReadBack(for: profileID)
    }

    func rollbackToLegacyAtIdle(for profileID: UUID) async throws {
        guard references[profileID] != nil else { return }
        states[profileID] = .active
    }

    func state(for profileID: UUID) -> HomeCredentialState? { states[profileID] }

    func removeCredential(for ownerID: UUID) async throws {
        if let reference = references.removeValue(forKey: ownerID) {
            values.removeValue(forKey: Self.key(reference))
        }
        states.removeValue(forKey: ownerID)
    }

    func containsAnyCredential(_ credential: Data) -> Bool {
        values.values.contains(credential)
    }

    func containsCredential(
        _ credential: Data,
        for reference: HomeCredentialReference
    ) -> Bool {
        values[Self.key(reference)] == credential
    }

    private static func key(_ reference: HomeCredentialReference) -> String {
        "\(reference.service)/\(reference.account)"
    }
}
