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

enum DeviceIdentityStatus: String, Codable, Equatable, Sendable {
    case verificationRequired
    case verified
    case unavailable
    case revoked

    var label: String {
        switch self {
        case .verificationRequired:
            "Verification required"
        case .verified:
            "Verified"
        case .unavailable:
            "Unavailable"
        case .revoked:
            "Revoked"
        }
    }

    var isOperational: Bool {
        self == .verified
    }

    var canRetryVerification: Bool {
        self == .verificationRequired || self == .unavailable
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

enum DeviceSetupStatus: String, Codable, Equatable, Sendable {
    case pending
    case ready
    case updatePending
    case verificationRequired
    case unavailable
    case revoked

    var label: String {
        switch self {
        case .pending:
            "Setup pending · Inactive"
        case .ready:
            "Ready"
        case .updatePending:
            "Update pending · Current mapping remains active"
        case .verificationRequired:
            "Verification required · Inactive"
        case .unavailable:
            "Unavailable · Inactive"
        case .revoked:
            "Revoked · Re-enrollment required"
        }
    }

    var isActive: Bool {
        self == .ready || self == .updatePending
    }

    var canVerify: Bool {
        self == .verificationRequired || self == .unavailable
    }
}

enum DeviceSetupStep: String, Codable, Equatable, Sendable {
    case room
    case wakeMappings
    case ready
    case complete
}

struct DeviceWakeMapping: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    var wakePhrase: String
    var profileIdentifier: String

    init(
        id: UUID = UUID(),
        wakePhrase: String = "",
        profileIdentifier: String = ""
    ) {
        self.id = id
        self.wakePhrase = wakePhrase
        self.profileIdentifier = profileIdentifier
    }

    var normalizedWakePhrase: String {
        wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    var hasValidValues: Bool {
        let normalizedProfile = normalizedProfileIdentifier
        return !normalizedWakePhrase.isEmpty
            && !normalizedProfile.isEmpty
            && !normalizedProfile.contains(where: \.isWhitespace)
    }

    var normalizedProfileIdentifier: String {
        profileIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DeviceSetupDraft: Codable, Equatable, Sendable {
    let deviceID: String
    let room: String
    let wakeMappings: [DeviceWakeMapping]
    let step: DeviceSetupStep

    init(
        deviceID: String,
        room: String,
        wakeMappings: [DeviceWakeMapping],
        step: DeviceSetupStep
    ) {
        self.deviceID = deviceID
        self.room = room
        self.wakeMappings = wakeMappings
        self.step = step
    }
}

struct DeviceSetupConfiguration: Codable, Equatable, Sendable {
    let deviceID: String
    let room: String
    let wakeMappings: [DeviceWakeMapping]
}

struct DeviceConfigurationState: Codable, Equatable, Sendable {
    let deviceID: String
    /// Locally approved identity used to rebuild the Devices list when an
    /// adapter does not return a previously approved Device.
    /// Older persisted states may omit this metadata.
    let approvedDevice: HouseholdDevice?
    let verifiedConfiguration: DeviceSetupConfiguration
    let pendingConfiguration: DeviceSetupConfiguration?
    var identityStatus: DeviceIdentityStatus

    init(
        approvedDevice: HouseholdDevice? = nil,
        verifiedConfiguration: DeviceSetupConfiguration,
        pendingConfiguration: DeviceSetupConfiguration?,
        identityStatus: DeviceIdentityStatus = .verified
    ) {
        self.deviceID = verifiedConfiguration.deviceID
        self.approvedDevice = approvedDevice.map {
            HouseholdDevice(
                id: $0.id,
                displayName: $0.displayName,
                kind: $0.kind,
                trustState: .approved
            )
        }
        self.verifiedConfiguration = verifiedConfiguration
        self.pendingConfiguration = pendingConfiguration
        self.identityStatus = identityStatus
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case approvedDevice
        case verifiedConfiguration
        case pendingConfiguration
        case identityStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let verifiedConfiguration = try container.decode(
            DeviceSetupConfiguration.self,
            forKey: .verifiedConfiguration
        )
        self.init(
            approvedDevice: try container.decodeIfPresent(
                HouseholdDevice.self,
                forKey: .approvedDevice
            ),
            verifiedConfiguration: verifiedConfiguration,
            pendingConfiguration: try container.decodeIfPresent(
                DeviceSetupConfiguration.self,
                forKey: .pendingConfiguration
            ),
            // Older files contain a locally verified configuration but no
            // current authority receipt. Missing status therefore fails
            // closed instead of restoring Ready from stale cache.
            identityStatus: try container.decodeIfPresent(
                DeviceIdentityStatus.self,
                forKey: .identityStatus
            ) ?? .verificationRequired
        )
    }
}

enum DeviceConfigurationPublicationStatus: String, Equatable, Sendable {
    case verified
    case pending
}

struct DeviceApprovalReceipt: Equatable, Sendable {
    /// A successful receipt means the future adapter provisioned the
    /// individually scoped credential. Raw credential material never crosses
    /// this boundary.
    let deviceID: String
}

struct DeviceConfigurationReceipt: Equatable, Sendable {
    let deviceID: String
    let configuration: DeviceSetupConfiguration

    /// Compare the publishable configuration while ignoring the local UUID
    /// used to identify an editable row in the iOS form.
    func matches(_ requested: DeviceSetupConfiguration) -> Bool {
        guard deviceID == requested.deviceID,
              configuration.deviceID == requested.deviceID,
              configuration.room == requested.room,
              configuration.wakeMappings.count == requested.wakeMappings.count
        else {
            return false
        }

        return zip(configuration.wakeMappings, requested.wakeMappings).allSatisfy {
            $0.wakePhrase == $1.wakePhrase
                && $0.profileIdentifier == $1.profileIdentifier
        }
    }
}

struct DeviceVerificationReceipt: Equatable, Sendable {
    let deviceID: String
    let status: DeviceIdentityStatus
    let configuration: DeviceSetupConfiguration?

    /// A verified identity is useful only when it confirms the exact
    /// publishable configuration that iOS already holds. Unavailable and
    /// revoked receipts intentionally never match an active configuration.
    func matches(_ requested: DeviceSetupConfiguration) -> Bool {
        guard status == .verified,
              let configuration
        else {
            return false
        }

        return DeviceConfigurationReceipt(
            deviceID: deviceID,
            configuration: configuration
        ).matches(requested)
    }
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
