import Foundation

#if os(iOS)
import UIKit
#endif

enum RelayConfigurationError: LocalizedError, Equatable, Sendable {
    case emptyToken
    case invalidTokenEncoding
    case invalidProfile

    var errorDescription: String? {
        switch self {
        case .emptyToken:
            return "The relay token cannot be empty."
        case .invalidTokenEncoding:
            return "The stored relay token is invalid. Replace it in Configure Relay."
        case .invalidProfile:
            return "The saved relay profile is invalid. Open Configure Relay and save it again."
        }
    }
}

actor RelayConfigurationStore {
    static let keychainService = "com.achappell.HermesRelayIOS.profile"
    static let tokenAccount = "default-token"

    private let secureStore: any SecureValueStore
    private let profileURL: URL

    init(secureStore: any SecureValueStore, profileURL: URL) {
        self.secureStore = secureStore
        self.profileURL = profileURL
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

    func saveProfile(_ profile: RelayProfile) async throws {
        var collection = try await loadCollection()
        collection.upsert(profile)
        if collection.selectedID == nil {
            collection.selectedID = profile.id
        }
        try await saveCollection(collection)
    }

    func deleteProfile(id: UUID) async throws {
        var collection = try await loadCollection()
        collection.remove(id: id)
        try await saveCollection(collection)
        try secureStore.delete(
            service: Self.keychainService, account: Self.tokenAccount(for: id)
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

    private func normalizedToken(_ data: Data?) throws -> String? {
        guard let data else { return nil }
        guard let token = String(data: data, encoding: .utf8) else {
            throw RelayConfigurationError.invalidTokenEncoding
        }
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw RelayConfigurationError.emptyToken }
        return normalized
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
            case .unsupportedEndpointScheme, .invalidEndpoint, .endpointContainsCredentials:
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
