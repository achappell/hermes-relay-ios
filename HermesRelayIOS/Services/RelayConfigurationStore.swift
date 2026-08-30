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
