import Foundation

#if os(iOS)
import UIKit
#endif

enum RelayConfigurationError: LocalizedError, Equatable, Sendable {
    case emptyToken
    case invalidTokenEncoding
    case invalidProfile
    case credentialRollbackFailed

    var errorDescription: String? {
        switch self {
        case .emptyToken:
            return "The relay token cannot be empty."
        case .invalidTokenEncoding:
            return "The stored relay token is invalid. Replace it in Configure Relay."
        case .invalidProfile:
            return "The saved relay profile is invalid. Open Configure Relay and save it again."
        case .credentialRollbackFailed:
            return "Configuration was not saved, and the previous Keychain state could not be restored. Check this connection's credential before trying again."
        }
    }
}

actor RelayConfigurationStore {
    static let keychainService = "com.achappell.HermesRelayIOS.profile"
    static let tokenAccount = "default-token"
    static let standardKeychainService = "com.achappell.HermesRelayIOS.standard"

    private let secureStore: any SecureValueStore
    private let profileURL: URL
    private let now: @Sendable () -> Date

    init(
        secureStore: any SecureValueStore,
        profileURL: URL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.secureStore = secureStore
        self.profileURL = profileURL
        self.now = now
    }

    static func tokenAccount(for id: UUID) -> String { id.uuidString }

    func loadCollection() async throws -> RelayProfileCollection {
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            return RelayProfileCollection()
        }

        let data = try Data(contentsOf: profileURL)
        do {
            return try JSONDecoder().decode(RelayProfileCollection.self, from: data)
        } catch is DecodingError {
            return try await migrateLegacyProfile(from: data)
        }
    }

    func saveCollection(_ collection: RelayProfileCollection) async throws {
        let directoryURL = profileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
        try JSONEncoder().encode(collection).write(to: profileURL, options: .atomic)
    }

    func transportMode(for profileID: UUID) async throws -> AppleTransportMode {
        try await loadCollection().transportMode(for: profileID)
    }

    func loadHomeMigration(for profileID: UUID) async throws -> HomeMigrationJournal? {
        try await loadCollection().homeMigrations[profileID]
    }

    func stageHomeMigration(
        for profileID: UUID,
        credential: HomeCredentialReference
    ) async throws {
        try credential.validate(for: profileID)
        var collection = try await loadCollection()
        guard collection.profiles.contains(where: { $0.id == profileID }) else {
            throw RelayConfigurationError.invalidProfile
        }
        collection.homeMigrations[profileID] = HomeMigrationJournal(
            schemaVersion: 1,
            profileID: profileID,
            phase: .staged,
            selectedMode: .legacy,
            credential: credential,
            legacyCredentialRetained: true,
            updatedAt: now()
        )
        try await saveCollection(collection)
    }

    func stageHomeMigration(
        profileID: UUID,
        credential: HomeCredentialReference
    ) async throws {
        try await stageHomeMigration(for: profileID, credential: credential)
    }

    func recordHomeReadBack(
        for profileID: UUID,
        credential: HomeCredentialReference? = nil
    ) async throws {
        try await updateHomeJournal(for: profileID, phase: .readBackVerified, credential: credential)
    }

    func recordHomeReadBack(
        profileID: UUID,
        credential: HomeCredentialReference? = nil
    ) async throws {
        try await recordHomeReadBack(for: profileID, credential: credential)
    }

    func recordFakeReady(for profileID: UUID) async throws {
        try await updateHomeJournal(for: profileID, phase: .fakeReadyVerified)
    }

    func recordFakeReady(profileID: UUID) async throws {
        try await recordFakeReady(for: profileID)
    }

    func recordLiveReady(for profileID: UUID) async throws {
        try await updateHomeJournal(for: profileID, phase: .liveReadyVerified)
    }

    func recordLiveReady(profileID: UUID) async throws {
        try await recordLiveReady(for: profileID)
    }

    func commitHomeMigration(for profileID: UUID) async throws {
        var collection = try await loadCollection()
        guard var journal = collection.homeMigrations[profileID],
              journal.profileID == profileID,
              journal.phase == .fakeReadyVerified || journal.phase == .liveReadyVerified,
              journal.credential != nil else {
            throw RelayConfigurationError.invalidProfile
        }
        journal.phase = .homeSelected
        journal.selectedMode = .home
        journal.legacyCredentialRetained = true
        journal.updatedAt = now()
        collection.homeMigrations[profileID] = journal
        try await saveCollection(collection)
    }

    /// The paired-client sibling of `commitHomeMigration`. A paired profile
    /// has no legacy relay token to migrate from; Home is selected for it
    /// only after the pairing proved one live `ready`. The credential
    /// reference stays with the pairing record, which owns its renewal.
    func selectPairedHome(for profileID: UUID) async throws {
        var collection = try await loadCollection()
        guard collection.profiles.contains(where: { $0.id == profileID }) else {
            throw RelayConfigurationError.invalidProfile
        }
        if collection.homeMigrations[profileID]?.phase == .homeSelected { return }
        collection.homeMigrations[profileID] = HomeMigrationJournal(
            schemaVersion: 1,
            profileID: profileID,
            phase: .homeSelected,
            selectedMode: .home,
            credential: nil,
            legacyCredentialRetained: false,
            updatedAt: now()
        )
        try await saveCollection(collection)
    }

    func rollbackHomeMigrationAtIdle(for profileID: UUID) async throws {
        var collection = try await loadCollection()
        guard var journal = collection.homeMigrations[profileID] else { return }
        journal.phase = .legacySelected
        journal.selectedMode = .legacy
        journal.legacyCredentialRetained = true
        journal.updatedAt = now()
        collection.homeMigrations[profileID] = journal
        try await saveCollection(collection)
    }

    func saveProfile(_ profile: RelayProfile) async throws {
        var collection = try await loadCollection()
        if let previous = collection.profiles.first(where: { $0.id == profile.id }),
           previous != profile {
            // Standard identity is immutable. Reconfiguration creates another
            // saved connection, retaining the original transcript for viewing.
            if previous.standardProfile != nil || profile.standardProfile != nil {
                guard previous.endpoint == profile.endpoint,
                      previous.standardProfile == profile.standardProfile else {
                    throw RelayConfigurationError.invalidProfile
                }
            } else if previous.endpoint != profile.endpoint {
                // Endpoint changes create a new connection identity. Never
                // destroy the old bearer or bind it to another host.
                throw RelayConfigurationError.invalidProfile
            }
        }
        collection.upsert(profile)
        if collection.selectedID == nil {
            collection.selectedID = profile.id
        }
        try await saveCollection(collection)
    }

    func saveStandardConnection(_ profile: RelayProfile, token: String) async throws {
        guard profile.standardProfile != nil else { throw RelayConfigurationError.invalidProfile }
        try await saveConnection(profile, token: token, service: Self.standardKeychainService)
    }

    func saveLegacyConnection(_ profile: RelayProfile, token: String) async throws {
        guard profile.standardProfile == nil else { throw RelayConfigurationError.invalidProfile }
        try await saveConnection(profile, token: token, service: Self.keychainService)
    }

    /// Commit profile and selection in one atomic file write. A failed write
    /// restores the credential snapshot; older connection accounts are untouched.
    private func saveConnection(_ profile: RelayProfile, token: String, service: String) async throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw RelayConfigurationError.emptyToken }
        var collection = try await loadCollection()
        let previous = collection.profiles.first(where: { $0.id == profile.id })
        if let previous {
            guard previous.endpoint == profile.endpoint,
                  previous.standardProfile == profile.standardProfile else {
                throw RelayConfigurationError.invalidProfile
            }
        }
        let account = Self.tokenAccount(for: profile.id)
        let priorCredential = try secureStore.read(service: service, account: account)
        let credential = Data(normalized.utf8)
        if profile.standardProfile != nil, previous != nil,
           let priorCredential, priorCredential != credential {
            // A different direct bearer is a different authorization identity.
            throw RelayConfigurationError.invalidProfile
        }
        let credentialChanged = priorCredential != credential
        if credentialChanged {
            try secureStore.write(credential, service: service, account: account)
        }
        collection.upsert(profile)
        collection.selectedID = profile.id
        do {
            try await saveCollection(collection)
        } catch {
            if credentialChanged {
                do {
                    if let priorCredential {
                        try secureStore.write(priorCredential, service: service, account: account)
                    } else {
                        try secureStore.delete(service: service, account: account)
                    }
                } catch {
                    throw RelayConfigurationError.credentialRollbackFailed
                }
            }
            throw error
        }
    }

    func deleteProfile(id: UUID) async throws {
        var collection = try await loadCollection()
        let isStandard = collection.profiles.first(where: { $0.id == id })?.standardProfile != nil
        collection.remove(id: id)
        try await saveCollection(collection)
        try secureStore.delete(
            service: isStandard ? Self.standardKeychainService : Self.keychainService,
            account: Self.tokenAccount(for: id)
        )
    }

    func selectProfile(id: UUID) async throws {
        var collection = try await loadCollection()
        guard collection.profiles.contains(where: { $0.id == id }) else {
            throw RelayConfigurationError.invalidProfile
        }
        collection.selectedID = id
        try await saveCollection(collection)
    }

    /// The active profile. ConversationStore and auto-connect use these, so
    /// they stay unaware that more than one profile exists.
    func loadProfile() async throws -> RelayProfile? {
        try await loadCollection().selectedProfile
    }

    func loadToken() async throws -> String? {
        guard let id = try await loadCollection().selectedID else { return nil }
        return try await loadToken(for: id)
    }

    func loadToken(for id: UUID) async throws -> String? {
        try normalizedToken(
            secureStore.read(
                service: Self.keychainService, account: Self.tokenAccount(for: id)
            )
        )
    }

    func saveToken(_ token: String, for id: UUID) async throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw RelayConfigurationError.emptyToken }
        try secureStore.write(
            Data(normalized.utf8),
            service: Self.keychainService,
            account: Self.tokenAccount(for: id)
        )
    }

    func deleteToken(for id: UUID) async throws {
        try secureStore.delete(
            service: Self.keychainService, account: Self.tokenAccount(for: id)
        )
    }

    func loadStandardToken(for id: UUID) async throws -> String? {
        try normalizedToken(
            secureStore.read(service: Self.standardKeychainService, account: Self.tokenAccount(for: id))
        )
    }

    func saveStandardToken(_ token: String, for id: UUID) async throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw RelayConfigurationError.emptyToken }
        try secureStore.write(
            Data(normalized.utf8), service: Self.standardKeychainService, account: Self.tokenAccount(for: id)
        )
    }

    func deleteStandardToken(for id: UUID) async throws {
        try secureStore.delete(
            service: Self.standardKeychainService, account: Self.tokenAccount(for: id)
        )
    }

    private func normalizedToken(_ data: Data?) throws -> String? {
        guard let data else { return nil }
        guard let token = String(data: data, encoding: .utf8) else {
            throw RelayConfigurationError.invalidTokenEncoding
        }
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw RelayConfigurationError.emptyToken }
        return normalized
    }

    private func updateHomeJournal(
        for profileID: UUID,
        phase: HomeMigrationPhase,
        credential: HomeCredentialReference? = nil
    ) async throws {
        var collection = try await loadCollection()
        guard var journal = collection.homeMigrations[profileID],
              journal.profileID == profileID else {
            throw RelayConfigurationError.invalidProfile
        }
        guard phase == .readBackVerified
                ? journal.phase == .staged
                : journal.phase == .readBackVerified else {
            throw RelayConfigurationError.invalidProfile
        }
        if let credential {
            try credential.validate(for: profileID)
            journal.credential = credential
        }
        journal.phase = phase
        journal.selectedMode = .legacy
        journal.updatedAt = now()
        collection.homeMigrations[profileID] = journal
        try await saveCollection(collection)
    }

    /// Copy, verify, then delete. A crash at any step leaves the token
    /// readable from at least one account, and re-running is safe.
    private func migrateLegacyProfile(from data: Data) async throws -> RelayProfileCollection {
        let legacyProfile: RelayProfile
        do {
            legacyProfile = try JSONDecoder().decode(RelayProfile.self, from: data)
        } catch {
            throw RelayConfigurationError.invalidProfile
        }

        try? FileManager.default.copyItem(
            at: profileURL,
            to: profileURL.appendingPathExtension("legacy-backup")
        )

        if let legacyToken = try normalizedToken(
            secureStore.read(service: Self.keychainService, account: Self.tokenAccount)
        ) {
            try secureStore.write(
                Data(legacyToken.utf8),
                service: Self.keychainService,
                account: Self.tokenAccount(for: legacyProfile.id)
            )
            let verified = try normalizedToken(
                secureStore.read(
                    service: Self.keychainService,
                    account: Self.tokenAccount(for: legacyProfile.id)
                )
            )
            guard verified == legacyToken else {
                throw RelayConfigurationError.invalidProfile
            }
        }

        let collection = RelayProfileCollection(
            profiles: [legacyProfile], selectedID: legacyProfile.id
        )
        try await saveCollection(collection)

        // Only now is the legacy secret redundant. A failure here is not fatal:
        // the token already lives under the profile's own account.
        try? secureStore.delete(
            service: Self.keychainService, account: Self.tokenAccount
        )

        return collection
    }
}

enum RelayConfigurationFormError: LocalizedError, Equatable, Sendable {
    case endpointRequired
    case invalidEndpoint
    case tokenRequired

    var errorDescription: String? {
        switch self {
        case .endpointRequired:
            return "Enter the Hermes relay endpoint."
        case .invalidEndpoint:
            return "Enter a valid relay endpoint using ws:// or wss://."
        case .tokenRequired:
            return "Enter a relay token before saving."
        }
    }
}

enum RelayConfigurationField: String, CaseIterable, Hashable, Sendable {
    case endpoint
    case clientID
    case deviceID
    case displayName
    case token
}

struct RelayDeviceIdentity: Equatable, Sendable {
    let deviceName: String

    init(deviceName: String) {
        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.deviceName = trimmedName.isEmpty ? "Apple device" : trimmedName
    }

    var clientID: String {
        "hermes-\(Self.platformIdentifier)-\(slug)"
    }

    var deviceID: String {
        slug
    }

    var displayName: String {
        deviceName
    }

    @MainActor
    static func current() -> Self {
        #if os(iOS)
        Self(deviceName: UIDevice.current.name)
        #elseif os(macOS)
        Self(deviceName: Host.current().localizedName ?? "Mac")
        #else
        Self(deviceName: "Apple device")
        #endif
    }

    private static var platformIdentifier: String {
        #if os(iOS)
        "ios"
        #elseif os(macOS)
        "mac"
        #else
        "apple"
        #endif
    }

    private var slug: String {
        let normalizedName = deviceName.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let separated = normalizedName.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined()
        let collapsed = separated.split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "device" : collapsed
    }
}

struct RelayConfigurationDraft: Equatable, Sendable {
    var endpoint: String
    var clientID: String
    var deviceID: String
    var displayName: String
    var token: String
    var hasStoredToken: Bool

    init(
        profile: RelayProfile? = nil,
        hasStoredToken: Bool = false,
        identity: RelayDeviceIdentity = RelayDeviceIdentity(deviceName: "Apple device")
    ) {
        endpoint = profile?.endpoint.absoluteString ?? ""
        clientID = profile?.clientID ?? identity.clientID
        deviceID = profile?.deviceID ?? identity.deviceID
        displayName = profile?.displayName ?? identity.displayName
        token = ""
        self.hasStoredToken = hasStoredToken
    }

    func makeProfile(id: UUID? = nil) throws -> RelayProfile {
        let endpointText = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpointText.isEmpty else {
            throw RelayConfigurationFormError.endpointRequired
        }
        guard let endpointURL = URL(string: endpointText) else {
            throw RelayConfigurationFormError.invalidEndpoint
        }

        do {
            return try RelayProfile(
                id: id ?? UUID(),
                endpoint: endpointURL,
                clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                deviceID: deviceID.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch let error as RelayProfileError {
            throw error
        } catch {
            throw RelayConfigurationFormError.invalidEndpoint
        }
    }

    func tokenToSave(existingToken: String?) throws -> String {
        let enteredToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !enteredToken.isEmpty {
            return enteredToken
        }
        guard let existingToken, !existingToken.isEmpty else {
            throw RelayConfigurationFormError.tokenRequired
        }
        return existingToken
    }

    var validationErrors: [RelayConfigurationField: String] {
        var errors: [RelayConfigurationField: String] = [:]

        do {
            _ = try makeProfile()
        } catch let error as RelayConfigurationFormError {
            switch error {
            case .endpointRequired, .invalidEndpoint:
                errors[.endpoint] = error.errorDescription
            case .tokenRequired:
                errors[.token] = error.errorDescription
            }
        } catch let error as RelayProfileError {
            switch error {
            case .unsupportedEndpointScheme, .invalidEndpoint, .endpointContainsCredentials,
                 .standardRequiresTLS, .standardEndpointPath:
                errors[.endpoint] = error.errorDescription
            case .emptyClientID:
                errors[.clientID] = error.errorDescription
            case .emptyDeviceID:
                errors[.deviceID] = error.errorDescription
            case .emptyDisplayName:
                errors[.displayName] = error.errorDescription
            }
        } catch {
            errors[.endpoint] = RelayConfigurationFormError.invalidEndpoint.errorDescription
        }

        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !hasStoredToken {
            errors[.token] = RelayConfigurationFormError.tokenRequired.errorDescription
        }

        return errors
    }
}
