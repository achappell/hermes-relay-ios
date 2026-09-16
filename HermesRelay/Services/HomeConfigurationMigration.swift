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
    case liveReadyFailed
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

enum HomeConfigurationMigrationReadiness: Equatable, Sendable {
    case fake
    case live
}

/// Coordinates the crash-safe conversion transaction. It persists the mode
/// only after secure read-back and a Home readiness proof have succeeded.
actor HomeConfigurationMigration {
    private let configurationStore: RelayConfigurationStore
    private let credentialStore: any HomeCredentialStore
    private let pairingHandoff: any HomePairingCredentialHandoff
    private let claimProvider: any HomeConversationClaimProvider
    private let homeClientFactory: any HomeBridgeSessionClientFactory
    private let readiness: HomeConfigurationMigrationReadiness

    init(
        configurationStore: RelayConfigurationStore,
        credentialStore: any HomeCredentialStore,
        pairingHandoff: any HomePairingCredentialHandoff,
        claimProvider: any HomeConversationClaimProvider,
        homeClientFactory: any HomeBridgeSessionClientFactory,
        readiness: HomeConfigurationMigrationReadiness = .fake
    ) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
        self.pairingHandoff = pairingHandoff
        self.claimProvider = claimProvider
        self.homeClientFactory = homeClientFactory
        self.readiness = readiness
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
                throw readiness == .live
                    ? HomeConfigurationMigrationError.liveReadyFailed
                    : HomeConfigurationMigrationError.fakeReadyFailed
            }
            switch readiness {
            case .fake:
                try await configurationStore.recordFakeReady(for: profileID)
            case .live:
                try await configurationStore.recordLiveReady(for: profileID)
            }
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
        case .notStarted, .staged, .readBackVerified, .fakeReadyVerified, .liveReadyVerified:
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

// MARK: - Operator-provisioned live Home configuration

enum HomeLiveConfigurationError: Error, LocalizedError, Equatable, Sendable {
    case emptyConversationHandle
    case invalidRoute(HomeRouteValidationError)
    case profileMismatch
    case invalidStorage
    case unsupportedSchema

    var errorDescription: String? {
        switch self {
        case .emptyConversationHandle:
            return "Enter the opaque Home conversation handle from the approved grant."
        case .invalidRoute(let error):
            return "The Home bridge route is invalid: \(error)."
        case .profileMismatch:
            return "The Home claim belongs to a different Hermes Profile."
        case .invalidStorage:
            return "The saved Home pairing metadata could not be read."
        case .unsupportedSchema:
            return "The saved Home pairing metadata uses an unsupported schema."
        }
    }
}

/// Non-secret metadata issued or approved by Home. The Device credential is
/// deliberately absent; it lives in `HomeCredentialKeychain` instead.
struct HomeLiveConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let profileID: UUID
    let conversationHandle: String
    let approvedRoute: HomeApprovedRoute

    init(
        profileID: UUID,
        conversationHandle: String,
        approvedRoute: HomeApprovedRoute,
        schemaVersion: Int = HomeLiveConfiguration.currentSchemaVersion
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw HomeLiveConfigurationError.unsupportedSchema
        }
        let normalizedHandle = conversationHandle.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedHandle.isEmpty else {
            throw HomeLiveConfigurationError.emptyConversationHandle
        }
        do {
            try approvedRoute.validate()
        } catch let error as HomeRouteValidationError {
            throw HomeLiveConfigurationError.invalidRoute(error)
        }
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.conversationHandle = normalizedHandle
        self.approvedRoute = approvedRoute
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            profileID: values.decode(UUID.self, forKey: .profileID),
            conversationHandle: values.decode(String.self, forKey: .conversationHandle),
            approvedRoute: values.decode(HomeApprovedRoute.self, forKey: .approvedRoute),
            schemaVersion: values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, profileID, conversationHandle, approvedRoute
    }

    func claim(for profileID: UUID) throws -> HomeConversationClaim {
        guard self.profileID == profileID else {
            throw HomeLiveConfigurationError.profileMismatch
        }
        return HomeConversationClaim(
            profileID: profileID,
            conversationHandle: conversationHandle,
            approvedRoute: approvedRoute
        )
    }
}

private struct HomeLiveConfigurationFile: Codable, Sendable {
    let schemaVersion: Int
    var configurations: [UUID: HomeLiveConfiguration]

    static let empty = HomeLiveConfigurationFile(
        schemaVersion: HomeLiveConfiguration.currentSchemaVersion,
        configurations: [:]
    )
}

protocol HomeLiveConfigurationStore: HomeApprovedRouteProvider,
    HomeConversationClaimProvider,
    Sendable {
    func configuration(for profileID: UUID) async throws -> HomeLiveConfiguration?
    func save(_ configuration: HomeLiveConfiguration) async throws
    func remove(profileID: UUID) async throws
}

/// Persists only the route and opaque claim. The corresponding Device secret
/// is never serialized here and is read from Keychain by the bridge client.
actor JSONHomeLiveConfigurationStore: HomeLiveConfigurationStore {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func configuration(for profileID: UUID) async throws -> HomeLiveConfiguration? {
        try readFile().configurations[profileID]
    }

    func save(_ configuration: HomeLiveConfiguration) async throws {
        var file = try readFile()
        file.configurations[configuration.profileID] = configuration
        try write(file)
    }

    func remove(profileID: UUID) async throws {
        var file = try readFile()
        file.configurations.removeValue(forKey: profileID)
        try write(file)
    }

    func approvedRoute(for profileID: UUID) async throws -> HomeApprovedRoute? {
        try await configuration(for: profileID)?.approvedRoute
    }

    func conversationClaim(for profileID: UUID) async throws -> HomeConversationClaim? {
        guard let configuration = try await configuration(for: profileID) else {
            return nil
        }
        return try configuration.claim(for: profileID)
    }

    private func readFile() throws -> HomeLiveConfigurationFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try JSONDecoder().decode(HomeLiveConfigurationFile.self, from: data)
            guard file.schemaVersion == HomeLiveConfiguration.currentSchemaVersion else {
                throw HomeLiveConfigurationError.unsupportedSchema
            }
            return file
        } catch let error as HomeLiveConfigurationError {
            throw error
        } catch {
            throw HomeLiveConfigurationError.invalidStorage
        }
    }

    private func write(_ file: HomeLiveConfigurationFile) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(file)
        try data.write(to: fileURL, options: .atomic)
    }
}

enum HomeLiveActivationError: Error, LocalizedError, Equatable, Sendable {
    case emptyCredential
    case profileMismatch
    case handshakeFailed

    var errorDescription: String? {
        switch self {
        case .emptyCredential:
            return "Enter the pre-issued Home Device credential."
        case .profileMismatch:
            return "The Home pairing metadata does not belong to the selected Hermes Profile."
        case .handshakeFailed:
            return "Home did not accept the live bridge handshake. Check the route, grant, and Device credential."
        }
    }
}

/// Performs the live pilot handoff: write the secret to Keychain, persist the
/// non-secret claim, prove `conversation.open`, then select Home in the
/// existing crash-safe migration journal.
actor HomeLiveActivation {
    private let configurationStore: RelayConfigurationStore
    private let credentialStore: any HomeCredentialProvisioningStore
    private let liveConfigurationStore: any HomeLiveConfigurationStore
    private let homeClientFactory: any HomeBridgeSessionClientFactory
    private let now: @Sendable () -> Date

    init(
        configurationStore: RelayConfigurationStore,
        credentialStore: any HomeCredentialProvisioningStore,
        liveConfigurationStore: any HomeLiveConfigurationStore,
        homeClientFactory: any HomeBridgeSessionClientFactory,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
        self.liveConfigurationStore = liveConfigurationStore
        self.homeClientFactory = homeClientFactory
        self.now = now
    }

    func activate(
        profileID: UUID,
        liveConfiguration: HomeLiveConfiguration,
        deviceCredential: Data
    ) async throws -> HomeConfigurationMigrationResult {
        guard liveConfiguration.profileID == profileID else {
            throw HomeLiveActivationError.profileMismatch
        }
        let reference: HomeCredentialReference
        if deviceCredential.isEmpty {
            do {
                reference = try await credentialStore.verifiedReadBack(for: profileID).reference
            } catch {
                throw HomeLiveActivationError.emptyCredential
            }
        } else {
            let issuedAt = now()
            let expiresAt = issuedAt.addingTimeInterval(90 * 24 * 60 * 60)
            reference = HomeCredentialReference(
                service: HomeCredentialKeychain.service,
                account: HomeCredentialKeychain.account(for: profileID),
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                renewAfter: expiresAt.addingTimeInterval(-14 * 24 * 60 * 60),
                overlapUntil: nil
            )
            try await credentialStore.provision(
                preIssuedCredential: deviceCredential,
                reference: reference,
                for: profileID
            )
        }
        try await liveConfigurationStore.save(liveConfiguration)

        let migration = HomeConfigurationMigration(
            configurationStore: configurationStore,
            credentialStore: credentialStore,
            pairingHandoff: FakeHomePairingCredentialHandoff(reference: reference),
            claimProvider: liveConfigurationStore,
            homeClientFactory: homeClientFactory,
            readiness: .live
        )
        do {
            return try await migration.migrate(profileID: profileID)
        } catch let error as HomeConfigurationMigrationError {
            if error == .liveReadyFailed {
                throw HomeLiveActivationError.handshakeFailed
            }
            throw error
        }
    }
}

struct FakeHomeBridgeSessionClientFactory: HomeBridgeSessionClientFactory {
    let client: any HomeBridgeSessionClient

    func make(profileID: UUID, mode: AppleTransportMode) -> any HomeBridgeSessionClient {
        client
    }
}
