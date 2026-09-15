import Foundation

enum HomeCredentialStoreError: Error, Equatable, Sendable {
    case missingCredential
    case invalidReference
    case unusableState(HomeCredentialState)
}

/// The reference metadata and the pre-issued value live in separate secure
/// records. The public API never returns the value; it exists only for the
/// duration of the private accessor closure.
actor KeychainHomeCredentialStore: HomeCredentialStore {
    private let secureStore: any SecureValueStore
    private var states: [UUID: HomeCredentialState] = [:]

    init(secureStore: any SecureValueStore) {
        self.secureStore = secureStore
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
actor InMemoryHomeCredentialStore: HomeCredentialStore {
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
