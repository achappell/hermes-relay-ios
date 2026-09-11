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

enum DeviceAdministrationError: Error, Equatable, Sendable {
    case approvalFailed
    case configurationFailed
    case revocationFailed
    case reEnrollmentFailed
    case unexpectedResponse
    case transportUnavailable

    var userMessage: String {
        switch self {
        case .approvalFailed:
            "The Device could not be approved. Try again."
        case .configurationFailed:
            "The Device setup could not be saved. Try again."
        case .revocationFailed:
            "Device access could not be revoked. It remains unavailable until you retry."
        case .reEnrollmentFailed:
            "The Device could not be re-enrolled. It remains unavailable. Try again."
        case .unexpectedResponse:
            "The Device identity could not be verified. Try again."
        case .transportUnavailable:
            "Device administration is not configured yet. Try again when a Device transport is available."
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

/// Adapter boundary for the trust transition and ordered setup that follows
/// identity discovery. A successful approval receipt asserts that the future
/// adapter provisioned an individual revocable credential; no secret bytes are
/// returned to the app model. Configuration is not active until its receipt
/// confirms the complete Room and Wake Mapping publish.
protocol DeviceAdministrationClient: Sendable {
    func approve(_ device: HouseholdDevice) async throws -> DeviceApprovalReceipt
    /// Revokes the Device Credential and Hermes access. The receipt contains
    /// identity only; credential material never crosses this boundary.
    func revoke(_ device: HouseholdDevice) async throws -> DeviceRevocationReceipt
    /// Starts explicit re-enrollment with a fresh credential. This receipt
    /// never promotes the Device to Ready; ordered setup must still complete.
    func reEnroll(_ device: HouseholdDevice) async throws -> DeviceReenrollmentReceipt
    func configure(
        _ configuration: DeviceSetupConfiguration
    ) async throws -> DeviceConfigurationReceipt
    /// Verifies the currently published Device identity and mapping. A
    /// successful `.verified` receipt is the only authority that may restore
    /// an active state after discovery; the production adapter remains
    /// unavailable until the shared Device contract exists.
    func verify(
        _ device: HouseholdDevice,
        against configuration: DeviceSetupConfiguration
    ) async throws -> DeviceVerificationReceipt
}

protocol DeviceConfigurationStore: Sendable {
    func loadAll() async throws -> [DeviceConfigurationState]
    func save(_ state: DeviceConfigurationState) async throws
}

extension DeviceConfigurationStore {
    func load(for deviceID: String) async throws -> DeviceConfigurationState? {
        try await loadAll().first { $0.deviceID == deviceID }
    }
}

struct NoopDeviceConfigurationStore: DeviceConfigurationStore {
    func loadAll() async throws -> [DeviceConfigurationState] {
        []
    }

    func save(_ state: DeviceConfigurationState) async throws {}
}

enum DeviceConfigurationPersistenceFile {
    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent("device-configurations.json")
    }
}

actor JSONDeviceConfigurationStore: DeviceConfigurationStore {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func loadAll() async throws -> [DeviceConfigurationState] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder()
            .decode(PersistedDeviceConfigurations.self, from: data)
            .states
    }

    func save(_ state: DeviceConfigurationState) async throws {
        var statesByID: [String: DeviceConfigurationState] = [:]
        for existing in try await loadAll() {
            statesByID[existing.deviceID] = existing
        }
        statesByID[state.deviceID] = state
        let states = statesByID.values.sorted { $0.deviceID < $1.deviceID }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder
            .encode(PersistedDeviceConfigurations(states: states))
            .write(to: fileURL, options: .atomic)

        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: fileURL.path
        )
        #endif
    }
}

private struct PersistedDeviceConfigurations: Codable, Sendable {
    let states: [DeviceConfigurationState]
}

enum DeviceConfigurationStoreFactory {
    static func make(in directory: URL) -> any DeviceConfigurationStore {
        JSONDeviceConfigurationStore(
            fileURL: DeviceConfigurationPersistenceFile.url(in: directory)
        )
    }
}

enum DeviceSetupDraftStoreError: Error, Equatable, Sendable {
    case invalidDeviceID

    var userMessage: String {
        switch self {
        case .invalidDeviceID:
            "The Device setup draft could not be identified."
        }
    }
}

protocol DeviceSetupDraftStore: Sendable {
    func loadAll() async throws -> [DeviceSetupDraft]
    func save(_ draft: DeviceSetupDraft) async throws
    func delete(deviceID: String) async throws
}

extension DeviceSetupDraftStore {
    func load(for deviceID: String) async throws -> DeviceSetupDraft? {
        guard !deviceID.isEmpty, !deviceID.contains(where: { $0.isWhitespace }) else {
            throw DeviceSetupDraftStoreError.invalidDeviceID
        }
        return try await loadAll().first { $0.deviceID == deviceID }
    }
}

struct NoopDeviceSetupDraftStore: DeviceSetupDraftStore {
    func loadAll() async throws -> [DeviceSetupDraft] {
        []
    }

    func save(_ draft: DeviceSetupDraft) async throws {}

    func delete(deviceID: String) async throws {}
}

enum DeviceSetupDraftPersistenceFile {
    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent("device-setup-drafts.json")
    }
}

actor JSONDeviceSetupDraftStore: DeviceSetupDraftStore {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func loadAll() async throws -> [DeviceSetupDraft] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder()
            .decode(PersistedDeviceSetupDrafts.self, from: data)
            .drafts
    }

    func save(_ draft: DeviceSetupDraft) async throws {
        guard !draft.deviceID.isEmpty,
              !draft.deviceID.contains(where: { $0.isWhitespace })
        else {
            throw DeviceSetupDraftStoreError.invalidDeviceID
        }

        var draftsByID: [String: DeviceSetupDraft] = [:]
        for existing in try await loadAll() {
            draftsByID[existing.deviceID] = existing
        }
        draftsByID[draft.deviceID] = draft
        try write(Array(draftsByID.values).sorted { $0.deviceID < $1.deviceID })
    }

    func delete(deviceID: String) async throws {
        guard !deviceID.isEmpty, !deviceID.contains(where: { $0.isWhitespace }) else {
            throw DeviceSetupDraftStoreError.invalidDeviceID
        }

        let remaining = try await loadAll().filter { $0.deviceID != deviceID }
        if remaining.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } else {
            try write(remaining)
        }
    }

    private func write(_ drafts: [DeviceSetupDraft]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(PersistedDeviceSetupDrafts(drafts: drafts))
        try data.write(to: fileURL, options: .atomic)

        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: fileURL.path
        )
        #endif
    }
}

private struct PersistedDeviceSetupDrafts: Codable, Sendable {
    let drafts: [DeviceSetupDraft]
}

enum DeviceSetupDraftStoreFactory {
    static func make(in directory: URL) -> any DeviceSetupDraftStore {
        JSONDeviceSetupDraftStore(
            fileURL: DeviceSetupDraftPersistenceFile.url(in: directory)
        )
    }
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

struct UnavailableDeviceAdministrationClient: DeviceAdministrationClient {
    func approve(_ device: HouseholdDevice) async throws -> DeviceApprovalReceipt {
        throw DeviceAdministrationError.transportUnavailable
    }

    func revoke(_ device: HouseholdDevice) async throws -> DeviceRevocationReceipt {
        throw DeviceAdministrationError.transportUnavailable
    }

    func reEnroll(_ device: HouseholdDevice) async throws -> DeviceReenrollmentReceipt {
        throw DeviceAdministrationError.transportUnavailable
    }

    func configure(
        _ configuration: DeviceSetupConfiguration
    ) async throws -> DeviceConfigurationReceipt {
        throw DeviceAdministrationError.transportUnavailable
    }

    func verify(
        _ device: HouseholdDevice,
        against configuration: DeviceSetupConfiguration
    ) async throws -> DeviceVerificationReceipt {
        throw DeviceAdministrationError.transportUnavailable
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

enum DeviceAdministrationClientFactory {
    static let unavailableFixtureLaunchArgument = "-HermesRelayDeviceAdministrationUnavailable"
    static let revokedFixtureLaunchArgument = "-HermesRelayDeviceAdministrationRevoked"

    static func make(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> any DeviceAdministrationClient {
        #if DEBUG
        if arguments.contains(unavailableFixtureLaunchArgument) {
            return UnavailableDeviceAdministrationClient()
        }
        if arguments.contains(revokedFixtureLaunchArgument) {
            return DebugDeviceAdministrationFixtureClient(verificationStatus: .revoked)
        }
        if arguments.contains(DeviceDiscoveryClientFactory.fixtureLaunchArgument) {
            return DebugDeviceAdministrationFixtureClient()
        }
        #endif

        return UnavailableDeviceAdministrationClient()
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

private struct DebugDeviceAdministrationFixtureClient: DeviceAdministrationClient {
    private let supportedDeviceIDs = [
        "unconfigured-hallway-puck",
        "unconfigured-study-display"
    ]
    private let verificationStatus: DeviceIdentityStatus

    init(verificationStatus: DeviceIdentityStatus = .verified) {
        self.verificationStatus = verificationStatus
    }

    func approve(_ device: HouseholdDevice) async throws -> DeviceApprovalReceipt {
        try await Task.sleep(nanoseconds: 500_000_000)
        guard supportedDeviceIDs.contains(device.id),
              device.trustState == .unconfigured
        else {
            throw DeviceAdministrationError.approvalFailed
        }
        return DeviceApprovalReceipt(deviceID: device.id)
    }

    func revoke(_ device: HouseholdDevice) async throws -> DeviceRevocationReceipt {
        try await Task.sleep(nanoseconds: 500_000_000)
        guard supportedDeviceIDs.contains(device.id),
              device.trustState == .approved
        else {
            throw DeviceAdministrationError.revocationFailed
        }
        return DeviceRevocationReceipt(deviceID: device.id)
    }

    func reEnroll(_ device: HouseholdDevice) async throws -> DeviceReenrollmentReceipt {
        try await Task.sleep(nanoseconds: 500_000_000)
        guard supportedDeviceIDs.contains(device.id),
              device.trustState == .approved
        else {
            throw DeviceAdministrationError.reEnrollmentFailed
        }
        return DeviceReenrollmentReceipt(deviceID: device.id)
    }

    func configure(
        _ configuration: DeviceSetupConfiguration
    ) async throws -> DeviceConfigurationReceipt {
        try await Task.sleep(nanoseconds: 500_000_000)
        guard supportedDeviceIDs.contains(configuration.deviceID) else {
            throw DeviceAdministrationError.configurationFailed
        }
        return DeviceConfigurationReceipt(
            deviceID: configuration.deviceID,
            configuration: configuration
        )
    }

    func verify(
        _ device: HouseholdDevice,
        against configuration: DeviceSetupConfiguration
    ) async throws -> DeviceVerificationReceipt {
        try await Task.sleep(nanoseconds: 500_000_000)
        guard supportedDeviceIDs.contains(device.id),
              device.trustState == .approved,
              configuration.deviceID == device.id
        else {
            throw DeviceAdministrationError.unexpectedResponse
        }
        return DeviceVerificationReceipt(
            deviceID: device.id,
            status: verificationStatus,
            configuration: configuration
        )
    }
}
#endif
