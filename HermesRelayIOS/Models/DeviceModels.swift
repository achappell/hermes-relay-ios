import Foundation

enum HouseholdDeviceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case puck
    case display

    var label: String {
        switch self {
        case .puck:
            "Puck"
        case .display:
            "Display"
        }
    }
}

enum HouseholdDeviceTrustState: String, Codable, Hashable, Sendable {
    case unconfigured
    case approved

    var label: String {
        switch self {
        case .unconfigured:
            "Unconfigured"
        case .approved:
            "Approved"
        }
    }
}

struct HouseholdDevice: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let kind: HouseholdDeviceKind
    let trustState: HouseholdDeviceTrustState

    var hasValidIdentifier: Bool {
        !id.isEmpty && !id.contains(where: \Character.isWhitespace)
    }
}

struct DeviceDiscoverySnapshot: Equatable, Sendable {
    let approvedDevices: [HouseholdDevice]
    let unconfiguredDevices: [HouseholdDevice]
}

/// Adapter-provided result after the shared Device handshake confirms the
/// requested identity. This slice does not define that handshake or create
/// credentials; the unavailable production adapter intentionally never emits
/// a receipt.
struct DeviceConnectionReceipt: Equatable, Sendable {
    let deviceID: String
}

enum DeviceConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case failed(DeviceDiscoveryError)

    var label: String {
        switch self {
        case .idle:
            "Not connected"
        case .connecting:
            "Connecting…"
        case .connected:
            "Connection confirmed"
        case let .failed(error):
            error.userMessage
        }
    }

    var systemImage: String {
        switch self {
        case .idle:
            "circle.dotted"
        case .connecting:
            "arrow.triangle.2.circlepath"
        case .connected:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle"
        }
    }
}
