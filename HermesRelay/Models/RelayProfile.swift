import Foundation

enum RelayProfileError: LocalizedError, Equatable, Sendable {
    case unsupportedEndpointScheme
    case invalidEndpoint
    case endpointContainsCredentials
    case emptyClientID
    case emptyDeviceID
    case emptyDisplayName
    case standardRequiresTLS
    case standardEndpointPath

    var errorDescription: String? {
        switch self {
        case .unsupportedEndpointScheme:
            return "The relay endpoint must use ws or wss."
        case .invalidEndpoint:
            return "The relay endpoint must include a host."
        case .endpointContainsCredentials:
            return "The relay endpoint must not contain credentials; store the bearer token separately."
        case .emptyClientID:
            return "The relay client ID cannot be empty."
        case .emptyDeviceID:
            return "The relay device ID cannot be empty."
        case .emptyDisplayName:
            return "The relay display name cannot be empty."
        case .standardRequiresTLS:
            return "Standard Hermes requires a secure wss:// endpoint."
        case .standardEndpointPath:
            return "Use the Standard Hermes endpoint at /api/ws, without query parameters or fragments."
        }
    }
}

struct RelayProfile: Codable, Equatable, Sendable {
    /// Stable identity. The display name is cosmetic: keying a profile's
    /// secret by name would orphan the token the moment it is renamed.
    let id: UUID
    let endpoint: URL
    let clientID: String
    let deviceID: String
    let displayName: String
    /// Nil identifies an existing Home/legacy profile, never direct Standard.
    let standardProfile: String?

    init(
        id: UUID = UUID(),
        endpoint: URL,
        clientID: String,
        deviceID: String,
        displayName: String,
        standardProfile: String? = nil
    ) throws {
        self.id = id
        guard let scheme = endpoint.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else {
            throw RelayProfileError.unsupportedEndpointScheme
        }
        guard endpoint.host != nil else {
            throw RelayProfileError.invalidEndpoint
        }
        guard endpoint.user == nil, endpoint.password == nil else {
            throw RelayProfileError.endpointContainsCredentials
        }
        if standardProfile != nil {
            guard scheme == "wss" else { throw RelayProfileError.standardRequiresTLS }
            guard endpoint.path == "" || endpoint.path == "/" || endpoint.path == "/api/ws",
                  endpoint.query == nil, endpoint.fragment == nil else {
                throw RelayProfileError.standardEndpointPath
            }
        }

        let normalizedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDeviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard standardProfile != nil || !normalizedClientID.isEmpty else {
            throw RelayProfileError.emptyClientID
        }
        guard standardProfile != nil || !normalizedDeviceID.isEmpty else {
            throw RelayProfileError.emptyDeviceID
        }
        guard !normalizedDisplayName.isEmpty else {
            throw RelayProfileError.emptyDisplayName
        }

        if standardProfile != nil {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.scheme = "wss"
            components.host = components.host?.lowercased()
            components.path = "/api/ws"
            self.endpoint = components.url!
        } else {
            self.endpoint = endpoint
        }
        self.clientID = normalizedClientID
        self.deviceID = normalizedDeviceID
        self.displayName = normalizedDisplayName
        self.standardProfile = standardProfile.map {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "default" : value
        }
    }

    static func standard(
        endpoint: URL,
        targetProfile: String = "default",
        id: UUID = UUID(),
        displayName: String = "Standard Hermes"
    ) throws -> RelayProfile {
        try RelayProfile(
            id: id, endpoint: endpoint, clientID: "", deviceID: "",
            displayName: displayName, standardProfile: targetProfile
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case endpoint
        case clientID
        case deviceID
        case displayName
        case standardProfile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            // Profiles written before saved-profile support have no id.
            // Mint one rather than throwing and stranding the configuration.
            id: container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            endpoint: container.decode(URL.self, forKey: .endpoint),
            clientID: container.decode(String.self, forKey: .clientID),
            deviceID: container.decode(String.self, forKey: .deviceID),
            displayName: container.decode(String.self, forKey: .displayName),
            standardProfile: container.decodeIfPresent(String.self, forKey: .standardProfile)
        )
    }
}
