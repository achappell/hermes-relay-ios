import Foundation

protocol HomeConversationClaimProvider: Sendable {
    func conversationClaim(for profileID: UUID) async throws -> HomeConversationClaim?
}

struct StaticHomeConversationClaimProvider: HomeConversationClaimProvider {
    let claim: HomeConversationClaim?

    func conversationClaim(for profileID: UUID) async throws -> HomeConversationClaim? {
        guard claim?.profileID == profileID else { return nil }
        return claim
    }
}

enum HomeConfigurationMigrationError: Error, Equatable, Sendable {
    case missingProfile
    case missingLegacyCredential
    case missingRouteClaim
    case fakeReadyFailed
    case invalidPhase
}

enum HomeConfigurationMigrationResult: Equatable, Sendable {
    case selectedHome
    case remainsLegacy(HomeMigrationPhase)
}

enum HomeConfigurationRecoveryResult: Equatable, Sendable {
    case legacy(HomeMigrationPhase)
    case home
    case retryable(HomeMigrationPhase)
}

/// Coordinates the crash-safe conversion transaction. It persists the mode
/// only after secure read-back and a fake-ready Home binding have succeeded.
actor HomeConfigurationMigration {
    private let configurationStore: RelayConfigurationStore
    private let credentialStore: any HomeCredentialStore
    private let pairingHandoff: any HomePairingCredentialHandoff
    private let claimProvider: any HomeConversationClaimProvider
    private let homeClientFactory: any HomeBridgeSessionClientFactory

    init(
        configurationStore: RelayConfigurationStore,
        credentialStore: any HomeCredentialStore,
        pairingHandoff: any HomePairingCredentialHandoff,
        claimProvider: any HomeConversationClaimProvider,
        homeClientFactory: any HomeBridgeSessionClientFactory
    ) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
        self.pairingHandoff = pairingHandoff
        self.claimProvider = claimProvider
        self.homeClientFactory = homeClientFactory
    }

    func migrate(profileID: UUID) async throws -> HomeConfigurationMigrationResult {
        guard let profile = try await configurationStore.loadProfile(), profile.id == profileID else {
            throw HomeConfigurationMigrationError.missingProfile
        }
        guard try await configurationStore.loadToken(for: profileID) != nil else {
            throw HomeConfigurationMigrationError.missingLegacyCredential
        }
        guard let reference = try await pairingHandoff.preIssuedReference(for: profileID) as HomeCredentialReference? else {
            throw HomeConfigurationMigrationError.invalidPhase
        }
        try reference.validate(for: profileID)
        try await credentialStore.stage(preIssued: reference, for: profileID)
        try await configurationStore.stageHomeMigration(for: profileID, credential: reference)

        do {
            let readBack = try await credentialStore.verifiedReadBack(for: profileID)
            guard readBack.profileID == profileID,
                  readBack.reference == reference,
                  readBack.state == .active else {
                throw HomeConfigurationMigrationError.invalidPhase
            }
            try await configurationStore.recordHomeReadBack(for: profileID, credential: reference)

            guard let claim = try await claimProvider.conversationClaim(for: profileID) else {
                throw HomeConfigurationMigrationError.missingRouteClaim
            }
            let client = homeClientFactory.make(profileID: profileID, mode: .home)
            defer { Task { await client.close() } }
            guard case .ready = await client.open(claim: claim) else {
                throw HomeConfigurationMigrationError.fakeReadyFailed
            }
            try await configurationStore.recordFakeReady(for: profileID)
            try await credentialStore.commitHomeSelection(for: profileID)
            try await configurationStore.commitHomeMigration(for: profileID)
            return .selectedHome
        } catch {
            if let journal = try? await configurationStore.loadHomeMigration(for: profileID),
               journal.phase != .legacySelected {
                try? await configurationStore.rollbackHomeMigrationAtIdle(for: profileID)
            }
            if let migrationError = error as? HomeConfigurationMigrationError {
                throw migrationError
            }
            throw error
        }
    }

    func recover(profileID: UUID) async throws -> HomeConfigurationRecoveryResult {
        guard let journal = try await configurationStore.loadHomeMigration(for: profileID) else {
            return .legacy(.notStarted)
        }
        switch journal.phase {
        case .homeSelected:
            guard let reference = journal.credential,
                  (try? reference.validate(for: profileID)) != nil,
                  let record = try? await credentialStore.verifiedReadBack(for: profileID),
                  record.state == .active else {
                return .retryable(.rollbackPending)
            }
            return .home
        case .notStarted, .staged, .readBackVerified, .fakeReadyVerified:
            return .retryable(journal.phase)
        case .rollbackPending, .legacySelected:
            return .legacy(journal.phase)
        }
    }

    func rollbackToLegacyAtIdle(profileID: UUID) async throws {
        try await credentialStore.rollbackToLegacyAtIdle(for: profileID)
        try await configurationStore.rollbackHomeMigrationAtIdle(for: profileID)
    }
}

struct FakeHomePairingCredentialHandoff: HomePairingCredentialHandoff {
    let reference: HomeCredentialReference

    func preIssuedReference(for profileID: UUID) async throws -> HomeCredentialReference {
        try reference.validate(for: profileID)
        return reference
    }
}

struct FakeHomeBridgeSessionClientFactory: HomeBridgeSessionClientFactory {
    let client: any HomeBridgeSessionClient

    func make(profileID: UUID, mode: AppleTransportMode) -> any HomeBridgeSessionClient {
        client
    }
}
