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
        HomeConfigurationIdentifierRules.isValid(rawValue)
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
    /// Home's display label for the Device. The local editor may not know it
    /// when it creates a new configuration, so the adapter falls back to the
    /// stable Device identifier on publish.
    let displayName: String?
    /// Home's single Profile reference for the Device. Older local editor
    /// state derives this from its Wake Mappings when it is absent.
    let profileIdentifier: String?
    let room: String
    let wakeMappings: [DeviceWakeMapping]
    /// Preserve Home's capability bit when a snapshot is read and written
    /// back. iOS does not infer or change arbitration eligibility.
    let wakeClaimEnabled: Bool
    /// Rank within the assigned Room. Lower values win an effective acoustic
    /// tie; the Home service validates uniqueness across Devices.
    let arbitrationPriority: Int?

    init(
        deviceID: String,
        room: String,
        wakeMappings: [DeviceWakeMapping],
        arbitrationPriority: Int? = nil,
        displayName: String? = nil,
        profileIdentifier: String? = nil,
        wakeClaimEnabled: Bool = true
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.profileIdentifier = profileIdentifier
        self.room = room
        self.wakeMappings = wakeMappings
        self.wakeClaimEnabled = wakeClaimEnabled
        self.arbitrationPriority = arbitrationPriority
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case displayName
        case profileIdentifier
        case room
        case wakeMappings
        case wakeClaimEnabled
        case arbitrationPriority
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
        profileIdentifier = try values.decodeIfPresent(
            String.self,
            forKey: .profileIdentifier
        )
        room = try values.decode(String.self, forKey: .room)
        wakeMappings = try values.decode([DeviceWakeMapping].self, forKey: .wakeMappings)
        wakeClaimEnabled = try values.decodeIfPresent(Bool.self, forKey: .wakeClaimEnabled) ?? true
        arbitrationPriority = try values.decodeIfPresent(Int.self, forKey: .arbitrationPriority)
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

struct HomeRoom: Codable, Equatable, Hashable, Sendable {
    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var hasValidValues: Bool {
        HomeConfigurationIdentifierRules.isValid(id)
            && HomeConfigurationIdentifierRules.isValidLabel(name)
    }
}

struct HomeConfigurationSnapshot: Codable, Equatable, Sendable {
    let revision: Int
    /// Room definitions are owned by Home. Older local snapshots may omit
    /// them, so decoding treats a missing field as an empty compatibility
    /// value; wire responses always carry the field.
    let rooms: [HomeRoom]
    let wakeMappings: [CanonicalWakeMapping]
    let devices: [DeviceSetupConfiguration]

    init(
        revision: Int,
        wakeMappings: [CanonicalWakeMapping],
        devices: [DeviceSetupConfiguration],
        rooms: [HomeRoom] = []
    ) {
        self.revision = revision
        self.rooms = rooms
        self.wakeMappings = wakeMappings
        self.devices = devices
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case rooms
        case wakeMappings
        case devices
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decode(Int.self, forKey: .revision)
        rooms = try values.decodeIfPresent([HomeRoom].self, forKey: .rooms) ?? []
        wakeMappings = try values.decode([CanonicalWakeMapping].self, forKey: .wakeMappings)
        devices = try values.decode([DeviceSetupConfiguration].self, forKey: .devices)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(revision, forKey: .revision)
        try values.encode(rooms, forKey: .rooms)
        try values.encode(wakeMappings, forKey: .wakeMappings)
        try values.encode(devices, forKey: .devices)
    }

    var validationErrors: [HomeConfigurationValidationError] {
        HomeConfigurationValidator.validate(self)
    }

    var isValid: Bool {
        validationErrors.isEmpty
    }

    /// The legacy editor snapshot remains decodable with omitted Home metadata,
    /// but a Home-backed operation requires the complete v1 projection.
    var isCompleteHomeSnapshot: Bool {
        guard isValid, devices.isEmpty || !rooms.isEmpty else { return false }

        return devices.allSatisfy { device in
            guard let displayName = device.displayName,
                  HomeConfigurationIdentifierRules.isValidLabel(displayName),
                  let profileIdentifier = device.profileIdentifier,
                  HomeConfigurationIdentifierRules.isValid(profileIdentifier),
                  device.arbitrationPriority != nil,
                  device.wakeMappings.count == wakeMappings.count
            else {
                return false
            }

            let normalizedProfile = profileIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return zip(device.wakeMappings, wakeMappings).allSatisfy { deviceMapping, catalogMapping in
                deviceMapping.canonicalID == catalogMapping.id
                    && deviceMapping.normalizedWakePhrase == catalogMapping.normalizedWakePhrase
                    && deviceMapping.normalizedProfileIdentifier == normalizedProfile
            }
        }
    }
}

enum HomeConfigurationValidationError: Equatable, Sendable {
    case invalidRevision
    case invalidRoomDefinition(String)
    case duplicateRoomID(String)
    case unknownRoom(deviceID: String, roomID: String)
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
    case invalidProfile(deviceID: String, profileID: String)
    case multipleProfiles(deviceID: String)
    case profileMismatch(deviceID: String, profileID: String)
}

private enum HomeConfigurationValidator {
    static func validate(
        _ snapshot: HomeConfigurationSnapshot
    ) -> [HomeConfigurationValidationError] {
        var errors: [HomeConfigurationValidationError] = []

        if snapshot.revision < 0 {
            errors.append(.invalidRevision)
        }

        var roomIDs = Set<String>()
        for room in snapshot.rooms {
            if !room.hasValidValues {
                errors.append(.invalidRoomDefinition(room.id))
            }
            if !roomIDs.insert(room.id).inserted {
                errors.append(.duplicateRoomID(room.id))
            }
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

            // Home IDs are opaque. Legacy local snapshots still normalize a
            // room label for duplicate-priority checks, but a complete Home
            // snapshot must match the exact Room ID it returned.
            let room = snapshot.rooms.isEmpty
                ? device.room.trimmingCharacters(in: .whitespacesAndNewlines)
                : device.room
            if room.isEmpty {
                errors.append(.invalidRoom(device.room))
            } else if !snapshot.rooms.isEmpty && !roomIDs.contains(room) {
                errors.append(.unknownRoom(deviceID: device.deviceID, roomID: room))
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
            var deviceProfiles = Set<String>()
            for mapping in device.wakeMappings {
                let profile = mapping.normalizedProfileIdentifier
                if !profile.isEmpty {
                    deviceProfiles.insert(profile)
                }
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

            if deviceProfiles.count > 1 {
                errors.append(.multipleProfiles(deviceID: device.deviceID))
            }
            if let profileIdentifier = device.profileIdentifier {
                let normalizedProfile = profileIdentifier.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard HomeConfigurationIdentifierRules.isValid(normalizedProfile) else {
                    errors.append(
                        .invalidProfile(
                            deviceID: device.deviceID,
                            profileID: profileIdentifier
                        )
                    )
                    continue
                }
                if !deviceProfiles.isEmpty,
                   !deviceProfiles.contains(normalizedProfile) {
                    errors.append(
                        .profileMismatch(
                            deviceID: device.deviceID,
                            profileID: normalizedProfile
                        )
                    )
                }
            }
        }

        return errors
    }
}

extension HomeConfigurationSnapshot {
    /// Returns a complete candidate snapshot with one Device replaced. Home
    /// remains the owner of rooms, mappings, priorities, and capabilities;
    /// this helper only preserves metadata that the local editor does not
    /// expose.
    func replacingDevice(
        _ configuration: DeviceSetupConfiguration,
        preservingHomeMetadata: Bool = false
    ) -> HomeConfigurationSnapshot? {
        guard let index = devices.firstIndex(where: {
            $0.deviceID == configuration.deviceID
        }) else {
            return nil
        }

        let current = devices[index]
        let mappingsByPhrase = Dictionary(
            grouping: wakeMappings,
            by: \CanonicalWakeMapping.normalizedWakePhrase
        )
        let resolvedWakeMappings = configuration.wakeMappings.compactMap { mapping -> DeviceWakeMapping? in
            guard mapping.canonicalID == nil else { return mapping }
            guard let matches = mappingsByPhrase[mapping.normalizedWakePhrase],
                  matches.count == 1,
                  let canonicalMapping = matches.first else {
                return nil
            }
            var resolved = mapping
            resolved.canonicalID = canonicalMapping.id
            return resolved
        }
        guard resolvedWakeMappings.count == configuration.wakeMappings.count else {
            return nil
        }
        let mappingProfiles = Set(
            resolvedWakeMappings.map(\DeviceWakeMapping.normalizedProfileIdentifier)
        )
        guard mappingProfiles.count <= 1 else { return nil }

        if preservingHomeMetadata {
            // The iOS editor may change an existing Device's Room, but the
            // global mapping catalog and Home's one-Profile projection are
            // read-only here. A changed row is an unsupported grant attempt,
            // not a local edit to be promoted.
            let mappingsMatchHome = resolvedWakeMappings.count == current.wakeMappings.count
                && zip(resolvedWakeMappings, current.wakeMappings).allSatisfy { requested, home in
                    requested.canonicalID == home.canonicalID
                        && requested.normalizedWakePhrase == home.normalizedWakePhrase
                        && requested.normalizedProfileIdentifier == home.normalizedProfileIdentifier
                }
            guard mappingsMatchHome else { return nil }
            if let profile = mappingProfiles.first,
               let currentProfile = current.profileIdentifier?.trimmingCharacters(
                   in: .whitespacesAndNewlines
               ),
               profile != currentProfile {
                return nil
            }
        }

        let profileIdentifier = preservingHomeMetadata
            ? current.profileIdentifier
            : mappingProfiles.count == 1
                ? mappingProfiles.first
                : configuration.profileIdentifier ?? current.profileIdentifier
        let requestedRoom = configuration.room
        let normalizedRequestedRoom = requestedRoom.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let fallbackRoom = preservingHomeMetadata
            ? requestedRoom
            : requestedRoom.trimmingCharacters(in: .whitespacesAndNewlines)
        let roomID = rooms.first(where: { $0.id == requestedRoom })?.id
            ?? rooms.first(where: { room in
                room.name.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                ) == normalizedRequestedRoom
            })?.id ?? fallbackRoom
        let replacement = DeviceSetupConfiguration(
            deviceID: configuration.deviceID,
            room: roomID,
            wakeMappings: resolvedWakeMappings,
            arbitrationPriority: preservingHomeMetadata
                ? current.arbitrationPriority
                : configuration.arbitrationPriority ?? current.arbitrationPriority,
            displayName: preservingHomeMetadata
                ? current.displayName
                : configuration.displayName ?? current.displayName,
            profileIdentifier: profileIdentifier,
            wakeClaimEnabled: preservingHomeMetadata
                ? current.wakeClaimEnabled
                : configuration.wakeClaimEnabled
        )
        var replacedDevices = devices
        replacedDevices[index] = replacement
        return HomeConfigurationSnapshot(
            revision: revision,
            wakeMappings: wakeMappings,
            devices: replacedDevices,
            rooms: rooms
        )
    }

    /// A PUT returns the complete activated snapshot. Treat it as a receipt,
    /// not merely an HTTP acknowledgement: Home must return the same
    /// household catalog and every Device field that iOS submitted.
    func matchesCandidate(
        _ candidate: HomeConfigurationSnapshot,
        minimumRevision: Int
    ) -> Bool {
        guard revision >= minimumRevision,
              isCompleteHomeSnapshot,
              candidate.isCompleteHomeSnapshot,
              rooms == candidate.rooms,
              wakeMappings == candidate.wakeMappings,
              devices.count == candidate.devices.count
        else {
            return false
        }

        return candidate.devices.allSatisfy { candidateDevice in
            guard let returnedDevice = devices.first(where: {
                $0.deviceID == candidateDevice.deviceID
            }) else {
                return false
            }
            guard returnedDevice.room == candidateDevice.room,
                  returnedDevice.displayName == candidateDevice.displayName,
                  returnedDevice.profileIdentifier == candidateDevice.profileIdentifier,
                  returnedDevice.arbitrationPriority == candidateDevice.arbitrationPriority,
                  returnedDevice.wakeClaimEnabled == candidateDevice.wakeClaimEnabled,
                  returnedDevice.wakeMappings.count == candidateDevice.wakeMappings.count,
                  zip(returnedDevice.wakeMappings, candidateDevice.wakeMappings).allSatisfy({ returned, sent in
                      returned.canonicalID == sent.canonicalID
                          && returned.wakePhrase == sent.wakePhrase
                          && returned.profileIdentifier == sent.profileIdentifier
                  }) else {
                return false
            }
            return DeviceConfigurationReceipt(
                deviceID: returnedDevice.deviceID,
                configuration: returnedDevice,
                homeConfigurationRevision: revision
            ).matches(candidateDevice)
        }
    }
}

private enum HomeConfigurationIdentifierRules {
    static func isValid(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.count <= 128
    }

    static func isValidLabel(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 128
    }
}

private extension String {
    var hasValidDeviceIdentifier: Bool {
        HomeConfigurationIdentifierRules.isValid(self)
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
    /// `nil` is the legacy Device-administration path. Home-backed state
    /// records whether its latest authoritative check allows operation.
    var homeEligibility: HomeDeviceEligibility?
    var identityStatus: DeviceIdentityStatus

    init(
        approvedDevice: HouseholdDevice? = nil,
        verifiedConfiguration: DeviceSetupConfiguration,
        pendingConfiguration: DeviceSetupConfiguration?,
        homeConfigurationRevision: Int? = nil,
        homeEligibility: HomeDeviceEligibility? = nil,
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
        self.homeEligibility = homeEligibility
        self.identityStatus = identityStatus
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case approvedDevice
        case verifiedConfiguration
        case pendingConfiguration
        case homeConfigurationRevision
        case homeEligibility
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
            homeEligibility: try container.decodeIfPresent(
                HomeDeviceEligibility.self,
                forKey: .homeEligibility
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

enum HomeDeviceEligibility: String, Codable, Equatable, Sendable {
    case eligible
    case ineligible
    case unavailable

    var allowsOperation: Bool { self == .eligible }
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
              configuration.displayName == requested.displayName,
              configuration.profileIdentifier == requested.profileIdentifier,
              configuration.wakeClaimEnabled == requested.wakeClaimEnabled,
              configuration.wakeMappings.count == requested.wakeMappings.count,
              configuration.arbitrationPriority == requested.arbitrationPriority
        else {
            return false
        }

        return zip(configuration.wakeMappings, requested.wakeMappings).allSatisfy {
            $0.canonicalID == $1.canonicalID
                && $0.normalizedWakePhrase == $1.normalizedWakePhrase
                && $0.normalizedProfileIdentifier == $1.normalizedProfileIdentifier
        }
    }

    func matches(
        _ requested: DeviceSetupConfiguration,
        minimumHomeRevision: Int
    ) -> Bool {
        homeConfigurationRevision.map { $0 >= minimumHomeRevision } == true
            && matches(requested)
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
