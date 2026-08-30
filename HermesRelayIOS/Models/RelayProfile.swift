import Foundation

enum RelayProfileError: LocalizedError, Equatable, Sendable {
    case unsupportedEndpointScheme
    case invalidEndpoint
    case emptyClientID
    case emptyDeviceID
    case emptyDisplayName

    var errorDescription: String? {
        switch self {
        case .unsupportedEndpointScheme:
            return "The relay endpoint must use ws or wss."
        case .invalidEndpoint:
            return "The relay endpoint must include a host."
        case .emptyClientID:
            return "The relay client ID cannot be empty."
        case .emptyDeviceID:
            return "The relay device ID cannot be empty."
        case .emptyDisplayName:
            return "The relay display name cannot be empty."
        }
    }
}

struct RelayProfile: Codable, Equatable, Sendable {
    let endpoint: URL
    let clientID: String
    let deviceID: String
    let displayName: String

    init(
        endpoint: URL,
        clientID: String,
        deviceID: String,
        displayName: String
    ) throws {
        guard let scheme = endpoint.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else {
            throw RelayProfileError.unsupportedEndpointScheme
        }
        guard endpoint.host != nil else {
            throw RelayProfileError.invalidEndpoint
        }
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RelayProfileError.emptyClientID
        }
        guard !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RelayProfileError.emptyDeviceID
        }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RelayProfileError.emptyDisplayName
        }

        self.endpoint = endpoint
        self.clientID = clientID
        self.deviceID = deviceID
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint
        case clientID
        case deviceID
        case displayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            endpoint: container.decode(URL.self, forKey: .endpoint),
            clientID: container.decode(String.self, forKey: .clientID),
            deviceID: container.decode(String.self, forKey: .deviceID),
            displayName: container.decode(String.self, forKey: .displayName)
        )
    }
}
