import Foundation

enum RelayConfigurationError: LocalizedError, Equatable, Sendable {
    case emptyToken
    case invalidTokenEncoding

    var errorDescription: String? {
        switch self {
        case .emptyToken:
            return "The relay token cannot be empty."
        case .invalidTokenEncoding:
            return "The stored relay token is not valid UTF-8."
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

    func loadProfile() async throws -> RelayProfile? {
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: profileURL)
        return try JSONDecoder().decode(RelayProfile.self, from: data)
    }

    func saveProfile(_ profile: RelayProfile) async throws {
        let directoryURL = profileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profile)
        try data.write(to: profileURL, options: .atomic)
    }

    func loadToken() async throws -> String? {
        guard let data = try secureStore.read(service: Self.keychainService, account: Self.tokenAccount) else {
            return nil
        }
        guard let token = String(data: data, encoding: .utf8) else {
            throw RelayConfigurationError.invalidTokenEncoding
        }
        return token
    }

    func saveToken(_ token: String) async throws {
        guard !token.isEmpty else { throw RelayConfigurationError.emptyToken }
        try secureStore.write(
            Data(token.utf8),
            service: Self.keychainService,
            account: Self.tokenAccount
        )
    }

    func deleteToken() async throws {
        try secureStore.delete(service: Self.keychainService, account: Self.tokenAccount)
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

struct RelayConfigurationDraft: Equatable, Sendable {
    var endpoint: String
    var clientID: String
    var deviceID: String
    var displayName: String
    var token: String
    var hasStoredToken: Bool

    init(profile: RelayProfile? = nil, hasStoredToken: Bool = false) {
        endpoint = profile?.endpoint.absoluteString ?? ""
        clientID = profile?.clientID ?? ""
        deviceID = profile?.deviceID ?? ""
        displayName = profile?.displayName ?? ""
        token = ""
        self.hasStoredToken = hasStoredToken
    }

    func makeProfile() throws -> RelayProfile {
        let endpointText = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpointText.isEmpty else {
            throw RelayConfigurationFormError.endpointRequired
        }
        guard let endpointURL = URL(string: endpointText) else {
            throw RelayConfigurationFormError.invalidEndpoint
        }

        do {
            return try RelayProfile(
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
}
