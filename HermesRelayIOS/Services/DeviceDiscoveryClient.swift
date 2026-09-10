import Foundation

enum DeviceDiscoveryError: Error, Equatable, Sendable {
    case lanUnavailable
    case manualPairingUnavailable
    case invalidIdentifier
    case deviceNotFound
    case connectionFailed
    case unexpectedResponse
    case transportUnavailable
    case discoveryInProgress

    var userMessage: String {
        switch self {
        case .lanUnavailable:
            "Device discovery is unavailable. Try manual pairing."
        case .manualPairingUnavailable:
            "Manual pairing is unavailable. Check the Device and try again."
        case .invalidIdentifier:
            "Enter a valid Device identifier."
        case .deviceNotFound:
            "That Device could not be found. Try discovery again."
        case .connectionFailed:
            "The Device could not be connected. Try again."
        case .unexpectedResponse:
            "The Device identity could not be verified. Try again."
        case .transportUnavailable:
            "Device discovery is not configured yet. Try again when a Device transport is available."
        case .discoveryInProgress:
            "Finish Device discovery before connecting."
        }
    }
}

/// Adapter boundary for physical Device identity discovery.
///
/// Implementations must keep discovery and connection side-effect free: these
/// operations may observe and verify a Device, but must not approve it, issue
/// credentials, wake it, capture audio, or submit a Hermes turn.
protocol DeviceDiscoveryClient: Sendable {
    /// Whether this adapter can identify a Device through the manual fallback.
    /// The production placeholder reports false so the UI never offers an
    /// action that is guaranteed to fail.
    var supportsManualPairing: Bool { get }
    func discover() async throws -> DeviceDiscoverySnapshot
    /// Opens the adapter's read-only identity connection and returns only
    /// after the shared Device handshake has confirmed the requested ID.
    func connect(to device: HouseholdDevice) async throws -> DeviceConnectionReceipt
    func identifyManually(_ identifier: String) async throws -> HouseholdDevice
}

extension DeviceDiscoveryClient {
    var supportsManualPairing: Bool { true }
}

struct UnavailableDeviceDiscoveryClient: DeviceDiscoveryClient {
    let supportsManualPairing = false

    func discover() async throws -> DeviceDiscoverySnapshot {
        throw DeviceDiscoveryError.lanUnavailable
    }

    func connect(to device: HouseholdDevice) async throws -> DeviceConnectionReceipt {
        throw DeviceDiscoveryError.connectionFailed
    }

    func identifyManually(_ identifier: String) async throws -> HouseholdDevice {
        throw DeviceDiscoveryError.manualPairingUnavailable
    }
}

/// Selects the shipped unavailable adapter unless a Debug-only simulator
/// fixture is explicitly requested. The fixture is a visual verification aid;
/// it is not a production discovery transport.
enum DeviceDiscoveryClientFactory {
    static let fixtureLaunchArgument = "-HermesRelayDeviceDiscoveryFixture"

    static func make(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> any DeviceDiscoveryClient {
        #if DEBUG
        if arguments.contains(fixtureLaunchArgument) {
            return DebugDeviceDiscoveryFixtureClient()
        }
        #endif

        return UnavailableDeviceDiscoveryClient()
    }
}

#if DEBUG
private struct DebugDeviceDiscoveryFixtureClient: DeviceDiscoveryClient {
    let supportsManualPairing = true

    private let approvedDevice = HouseholdDevice(
        id: "approved-kitchen-display",
        displayName: "Kitchen Display",
        kind: .display,
        trustState: .approved
    )
    private let successfulCandidate = HouseholdDevice(
        id: "unconfigured-hallway-puck",
        displayName: "Hallway Puck",
        kind: .puck,
        trustState: .unconfigured
    )
    private let failingCandidate = HouseholdDevice(
        id: "unconfigured-study-display",
        displayName: "Study Display",
        kind: .display,
        trustState: .unconfigured
    )

    func discover() async throws -> DeviceDiscoverySnapshot {
        DeviceDiscoverySnapshot(
            approvedDevices: [approvedDevice],
            unconfiguredDevices: [successfulCandidate, failingCandidate]
        )
    }

    func connect(to device: HouseholdDevice) async throws -> DeviceConnectionReceipt {
        try await Task.sleep(nanoseconds: 750_000_000)

        switch device.id {
        case successfulCandidate.id:
            return DeviceConnectionReceipt(deviceID: device.id)
        case failingCandidate.id:
            throw DeviceDiscoveryError.connectionFailed
        default:
            throw DeviceDiscoveryError.deviceNotFound
        }
    }

    func identifyManually(_ identifier: String) async throws -> HouseholdDevice {
        switch identifier {
        case successfulCandidate.id:
            return successfulCandidate
        case failingCandidate.id:
            return failingCandidate
        default:
            throw DeviceDiscoveryError.deviceNotFound
        }
    }
}
#endif
