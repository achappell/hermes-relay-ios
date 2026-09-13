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
    case revocationPending
    case revoked

    var label: String {
        switch self {
        case .verificationRequired:
            "Verification required"
        case .verified:
            "Verified"
        case .unavailable:
            "Unavailable"
        case .revocationPending:
            "Revocation pending"
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
    case revocationPending
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
        case .revocationPending:
            "Revocation pending · Inactive"
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

/// Opaque identifier for a household-level wake trigger. The Home service
/// owns its value; iOS persists and transports it but never derives it from a
/// wake phrase or Hermes Profile identifier.
struct CanonicalWakeMappingID: Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var isValid: Bool {
        !rawValue.isEmpty && !rawValue.contains(where: \Character.isWhitespace)
    }
}

struct DeviceWakeMapping: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    /// Local editor identity. This is intentionally distinct from the
    /// server-owned identifier used to group simultaneous wake claims.
    var canonicalID: CanonicalWakeMappingID?
    var wakePhrase: String
    var profileIdentifier: String

    init(
        id: UUID = UUID(),
        wakePhrase: String = "",
        profileIdentifier: String = "",
        canonicalID: CanonicalWakeMappingID? = nil
    ) {
        self.id = id
        self.canonicalID = canonicalID
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
    let arbitrationPriority: Int?

    init(
        deviceID: String,
        room: String,
        wakeMappings: [DeviceWakeMapping],
        step: DeviceSetupStep,
        arbitrationPriority: Int? = nil
    ) {
        self.deviceID = deviceID
        self.room = room
        self.wakeMappings = wakeMappings
        self.step = step
        self.arbitrationPriority = arbitrationPriority
    }
}

struct DeviceSetupConfiguration: Codable, Equatable, Sendable {
    let deviceID: String
    let room: String
    let wakeMappings: [DeviceWakeMapping]
    /// Rank within the assigned Room. Lower values win an effective acoustic
    /// tie; the Home service validates uniqueness across Devices.
    let arbitrationPriority: Int?

    init(
        deviceID: String,
        room: String,
        wakeMappings: [DeviceWakeMapping],
        arbitrationPriority: Int? = nil
    ) {
        self.deviceID = deviceID
        self.room = room
        self.wakeMappings = wakeMappings
        self.arbitrationPriority = arbitrationPriority
    }
}

struct CanonicalWakeMapping: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: CanonicalWakeMappingID
    let wakePhrase: String

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
        id.isValid && !normalizedWakePhrase.isEmpty
    }
}

struct HomeConfigurationSnapshot: Codable, Equatable, Sendable {
    let revision: Int
    let wakeMappings: [CanonicalWakeMapping]
    let devices: [DeviceSetupConfiguration]

    var validationErrors: [HomeConfigurationValidationError] {
        HomeConfigurationValidator.validate(self)
    }

    var isValid: Bool {
        validationErrors.isEmpty
    }
}

enum HomeConfigurationValidationError: Equatable, Sendable {
    case invalidRevision
    case invalidMapping(CanonicalWakeMappingID)
    case duplicateMappingID(CanonicalWakeMappingID)
    case duplicateMappingPhrase(String)
    case invalidDeviceID(String)
    case duplicateDeviceID(String)
    case invalidRoom(String)
    case invalidPriority(String)
    case duplicatePriority(room: String, priority: Int)
    case invalidDeviceMapping(deviceID: String, mappingID: CanonicalWakeMappingID)
    case unknownMapping(deviceID: String, mappingID: CanonicalWakeMappingID)
    case mappingPhraseMismatch(deviceID: String, mappingID: CanonicalWakeMappingID)
}

private enum HomeConfigurationValidator {
    static func validate(
        _ snapshot: HomeConfigurationSnapshot
    ) -> [HomeConfigurationValidationError] {
        var errors: [HomeConfigurationValidationError] = []

        if snapshot.revision < 0 {
            errors.append(.invalidRevision)
        }

        var mappingIDs = Set<CanonicalWakeMappingID>()
        var mappingPhrases = Set<String>()
        var mappingsByID: [CanonicalWakeMappingID: CanonicalWakeMapping] = [:]
        for mapping in snapshot.wakeMappings {
            if !mapping.hasValidValues {
                errors.append(.invalidMapping(mapping.id))
            }
            if !mappingIDs.insert(mapping.id).inserted {
                errors.append(.duplicateMappingID(mapping.id))
            }
            if !mappingPhrases.insert(mapping.normalizedWakePhrase).inserted {
                errors.append(.duplicateMappingPhrase(mapping.normalizedWakePhrase))
            }
            mappingsByID[mapping.id] = mapping
        }

        var deviceIDs = Set<String>()
        var prioritiesByRoom: [String: Set<Int>] = [:]
        for device in snapshot.devices {
            guard device.deviceID.hasValidDeviceIdentifier else {
                errors.append(.invalidDeviceID(device.deviceID))
                continue
            }
            if !deviceIDs.insert(device.deviceID).inserted {
                errors.append(.duplicateDeviceID(device.deviceID))
            }

            let room = device.room.trimmingCharacters(in: .whitespacesAndNewlines)
            if room.isEmpty {
                errors.append(.invalidRoom(device.room))
            }

            guard let priority = device.arbitrationPriority,
                  priority > 0
            else {
                errors.append(.invalidPriority(device.deviceID))
                continue
            }
            var roomPriorities = prioritiesByRoom[room, default: []]
            if !roomPriorities.insert(priority).inserted {
                errors.append(.duplicatePriority(room: room, priority: priority))
            }
            prioritiesByRoom[room] = roomPriorities

            var deviceMappingIDs = Set<CanonicalWakeMappingID>()
            for mapping in device.wakeMappings {
                guard let canonicalID = mapping.canonicalID,
                      canonicalID.isValid
                else {
                    errors.append(
                        .invalidDeviceMapping(
                            deviceID: device.deviceID,
                            mappingID: mapping.canonicalID ?? CanonicalWakeMappingID("")
                        )
                    )
                    continue
                }
                if !deviceMappingIDs.insert(canonicalID).inserted {
                    errors.append(
                        .invalidDeviceMapping(
                            deviceID: device.deviceID,
                            mappingID: canonicalID
                        )
                    )
                }
                guard mappingIDs.contains(canonicalID) else {
                    errors.append(
                        .unknownMapping(deviceID: device.deviceID, mappingID: canonicalID)
                    )
                    continue
                }
                if let canonicalMapping = mappingsByID[canonicalID],
                   canonicalMapping.normalizedWakePhrase != mapping.normalizedWakePhrase {
                    errors.append(
                        .mappingPhraseMismatch(
                            deviceID: device.deviceID,
                            mappingID: canonicalID
                        )
                    )
                }
            }
        }

        return errors
    }
}

private extension String {
    var hasValidDeviceIdentifier: Bool {
        !isEmpty && !contains(where: \Character.isWhitespace)
    }
}

struct DeviceConfigurationState: Codable, Equatable, Sendable {
    let deviceID: String
    /// Locally approved identity used to rebuild the Devices list when an
    /// adapter does not return a previously approved Device.
    /// Older persisted states may omit this metadata.
    let approvedDevice: HouseholdDevice?
    let verifiedConfiguration: DeviceSetupConfiguration
    let pendingConfiguration: DeviceSetupConfiguration?
    /// Revision of the Home service snapshot that produced the verified
    /// configuration. Older local state may not have this value.
    let homeConfigurationRevision: Int?
    var identityStatus: DeviceIdentityStatus

    init(
        approvedDevice: HouseholdDevice? = nil,
        verifiedConfiguration: DeviceSetupConfiguration,
        pendingConfiguration: DeviceSetupConfiguration?,
        homeConfigurationRevision: Int? = nil,
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
        self.homeConfigurationRevision = homeConfigurationRevision
        self.identityStatus = identityStatus
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case approvedDevice
        case verifiedConfiguration
        case pendingConfiguration
        case homeConfigurationRevision
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
            homeConfigurationRevision: try container.decodeIfPresent(
                Int.self,
                forKey: .homeConfigurationRevision
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

struct DeviceRevocationReceipt: Equatable, Sendable {
    /// A successful receipt confirms that the Device Credential and Hermes
    /// access were revoked. Raw credential material never crosses this seam.
    let deviceID: String
}

struct DeviceReenrollmentReceipt: Equatable, Sendable {
    /// A successful receipt confirms that explicit re-enrollment provisioned a
    /// new individually scoped credential. It never makes the Device Ready.
    let deviceID: String
}

struct DeviceConfigurationReceipt: Equatable, Sendable {
    let deviceID: String
    let configuration: DeviceSetupConfiguration
    let homeConfigurationRevision: Int?

    init(
        deviceID: String,
        configuration: DeviceSetupConfiguration,
        homeConfigurationRevision: Int? = nil
    ) {
        self.deviceID = deviceID
        self.configuration = configuration
        self.homeConfigurationRevision = homeConfigurationRevision
    }

    /// Compare the publishable configuration while ignoring the local UUID
    /// used to identify an editable row in the iOS form.
    func matches(_ requested: DeviceSetupConfiguration) -> Bool {
        guard deviceID == requested.deviceID,
              configuration.deviceID == requested.deviceID,
              configuration.room == requested.room,
              configuration.wakeMappings.count == requested.wakeMappings.count,
              configuration.arbitrationPriority == requested.arbitrationPriority
        else {
            return false
        }

        return zip(configuration.wakeMappings, requested.wakeMappings).allSatisfy {
            $0.canonicalID == $1.canonicalID
                && $0.wakePhrase == $1.wakePhrase
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
