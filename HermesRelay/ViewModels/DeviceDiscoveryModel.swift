import Foundation
import Observation

@MainActor
@Observable
final class DeviceDiscoveryModel {
    private(set) var approvedDevices: [HouseholdDevice] = []
    private(set) var discoveredDevices: [HouseholdDevice] = []
    private(set) var isApproving = false
    private(set) var isVerifying = false
    private(set) var isDiscovering = false
    private(set) var isReenrolling = false
    private(set) var errorMessage: String?
    /// A discovery-specific failure gets its own recovery affordance in the
    /// list. Other errors belong to the action that produced them.
    private(set) var discoveryErrorMessage: String?
    private(set) var isManualFallbackAvailable = false
    private(set) var statusMessage: String?
    var manualIdentifier = ""
    private(set) var isPairingManually = false
    private var connectionStates: [String: DeviceConnectionState] = [:]
    private var setupStatuses: [String: DeviceSetupStatus] = [:]
    private var setupDrafts: [String: DeviceSetupDraft] = [:]
    private var configurationStates: [String: DeviceConfigurationState] = [:]
    private var discoveryRequestID = 0

    private let client: any DeviceDiscoveryClient
    private let administrationClient: any DeviceAdministrationClient
    private let draftStore: any DeviceSetupDraftStore
    private let configurationStore: any DeviceConfigurationStore

    init(
        client: any DeviceDiscoveryClient,
        administrationClient: any DeviceAdministrationClient = UnavailableDeviceAdministrationClient(),
        draftStore: any DeviceSetupDraftStore = NoopDeviceSetupDraftStore(),
        configurationStore: any DeviceConfigurationStore = NoopDeviceConfigurationStore()
    ) {
        self.client = client
        self.administrationClient = administrationClient
        self.draftStore = draftStore
        self.configurationStore = configurationStore
    }

    func discover() async {
        discoveryRequestID += 1
        let requestID = discoveryRequestID
        isDiscovering = true
        errorMessage = nil
        discoveryErrorMessage = nil
        isManualFallbackAvailable = false
        let connectingIDs = connectionStates.compactMap { id, state in
            state == .connecting ? id : nil
        }
        for id in connectingIDs {
            connectionStates[id] = .idle
        }
        defer {
            if discoveryRequestID == requestID {
                isDiscovering = false
            }
        }

        do {
            let snapshot = try await client.discover()
            guard discoveryRequestID == requestID else { return }
            let draftLoadError = await loadSetupDrafts()
            guard discoveryRequestID == requestID else { return }
            let configurationLoadError = await loadConfigurationStates()
            guard discoveryRequestID == requestID else { return }
            let snapshotDevices = snapshot.approvedDevices + snapshot.unconfiguredDevices
            let persistedApproved = configurationStates.values.compactMap { state in
                state.approvedDevice
                    ?? snapshotDevices.first { $0.id == state.deviceID }
            }
            let draftedApproved = setupDrafts.keys.compactMap { deviceID in
                snapshotDevices.first { $0.id == deviceID }
            }
            let locallyApproved = approvedDevices.filter {
                setupStatuses[$0.id] != nil
                    || setupDrafts[$0.id] != nil
                    || configurationStates[$0.id] != nil
            } + persistedApproved + draftedApproved
            let approved = uniqueDevices(
                snapshot.approvedDevices + locallyApproved.map(asApprovedDevice),
                withTrustState: .approved
            )
            let approvedIDs = Set(approved.map(\.id))
            let discovered = uniqueDevices(
                snapshot.unconfiguredDevices,
                withTrustState: .unconfigured
            ).filter { !approvedIDs.contains($0.id) }

            errorMessage = draftLoadError ?? configurationLoadError
            approvedDevices = approved
            discoveredDevices = discovered
            let discoveredIDs = Set(discovered.map(\.id))
            connectionStates = connectionStates.filter {
                discoveredIDs.contains($0.key)
            }
            for device in discovered where connectionStates[device.id] == nil {
                connectionStates[device.id] = .idle
            }
            statusMessage = nil
            discoveryErrorMessage = nil
            await verifyConfiguredDevices(approved, requestID: requestID)
        } catch is CancellationError {
            return
        } catch let error as DeviceDiscoveryError {
            guard discoveryRequestID == requestID else { return }
            errorMessage = discoveryMessage(for: error)
            discoveryErrorMessage = errorMessage
            isManualFallbackAvailable = error == .lanUnavailable
                && client.supportsManualPairing
        } catch {
            guard discoveryRequestID == requestID else { return }
            errorMessage = "Device discovery failed. Try again."
            discoveryErrorMessage = errorMessage
        }
    }

    private func uniqueDevices(
        _ devices: [HouseholdDevice],
        withTrustState trustState: HouseholdDeviceTrustState
    ) -> [HouseholdDevice] {
        var seenIDs = Set<String>()
        return devices.filter { device in
            device.hasValidIdentifier
                && device.trustState == trustState
                && seenIDs.insert(device.id).inserted
        }
    }

    private func asApprovedDevice(_ device: HouseholdDevice) -> HouseholdDevice {
        HouseholdDevice(
            id: device.id,
            displayName: device.displayName,
            kind: device.kind,
            trustState: .approved
        )
    }

    private func discoveryMessage(for error: DeviceDiscoveryError) -> String {
        if error == .lanUnavailable && !client.supportsManualPairing {
            return DeviceDiscoveryError.transportUnavailable.userMessage
        }
        return error.userMessage
    }

    func beginManualPairing() {
        manualIdentifier = ""
        errorMessage = nil
        statusMessage = nil
    }

    func submitManualPairing() async -> Bool {
        let identifier = manualIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              !identifier.contains(where: \Character.isWhitespace)
        else {
            errorMessage = DeviceDiscoveryError.invalidIdentifier.userMessage
            return false
        }

        isPairingManually = true
        errorMessage = nil
        defer { isPairingManually = false }

        do {
            let device = try await client.identifyManually(identifier)
            guard device.hasValidIdentifier,
                  device.id == identifier,
                  device.trustState == .unconfigured,
                  !approvedDevices.contains(where: { $0.id == device.id })
            else {
                throw DeviceDiscoveryError.unexpectedResponse
            }

            if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                discoveredDevices[index] = device
            } else {
                discoveredDevices.append(device)
            }
            if connectionStates[device.id] == nil {
                connectionStates[device.id] = .idle
            }
            statusMessage = "\(device.displayName) found. It remains unconfigured."
            isManualFallbackAvailable = false
            return true
        } catch let error as DeviceDiscoveryError {
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = DeviceDiscoveryError.manualPairingUnavailable.userMessage
            return false
        }
    }

    func connectionState(for device: HouseholdDevice) -> DeviceConnectionState {
        connectionStates[device.id] ?? .idle
    }

    func setupStatus(for device: HouseholdDevice) -> DeviceSetupStatus? {
        if let configurationState = configurationStates[device.id] {
            return setupStatus(for: configurationState)
        }
        return setupStatuses[device.id] ?? (setupDrafts[device.id] == nil ? nil : .pending)
    }

    func hasSetupDraft(for device: HouseholdDevice) -> Bool {
        setupDrafts[device.id] != nil
    }

    func refreshSetupDrafts() async {
        let draftError = await loadSetupDrafts()
        let configurationError = await loadConfigurationStates()
        errorMessage = draftError ?? configurationError
        await verifyConfiguredDevices(approvedDevices, requestID: discoveryRequestID)
    }

    func configurationState(for device: HouseholdDevice) -> DeviceConfigurationState? {
        configurationStates[device.id]
    }

    func approvedDevice(for device: HouseholdDevice) -> HouseholdDevice? {
        approvedDevices.first { $0.id == device.id }
    }

    func isActive(_ device: HouseholdDevice) -> Bool {
        setupStatus(for: device)?.isActive == true
    }

    func markReady(_ device: HouseholdDevice) {
        guard setupStatus(for: device) == .pending else { return }
        setupStatuses[device.id] = .ready
        setupDrafts.removeValue(forKey: device.id)
        statusMessage = "\(device.displayName) is ready and active."
    }

    /// Re-checks a configured Device against the administration authority.
    /// A local configuration file is useful cached context, never proof that
    /// the Device or its mapped Profiles are still usable.
    func verify(_ device: HouseholdDevice) async {
        guard !isVerifying else { return }
        isVerifying = true
        defer { isVerifying = false }
        await verifyConfiguredDevice(device, requestID: discoveryRequestID)
    }

    func approve(_ device: HouseholdDevice) async -> Bool {
        guard connectionState(for: device) == .connected else {
            errorMessage = "Confirm the Device connection before approving it."
            return false
        }
        guard let currentDevice = discoveredDevices.first(where: { $0.id == device.id }),
              currentDevice.trustState == .unconfigured
        else {
            errorMessage = DeviceDiscoveryError.deviceNotFound.userMessage
            return false
        }
        guard !isApproving else { return false }

        isApproving = true
        errorMessage = nil
        statusMessage = nil
        let requestID = discoveryRequestID
        defer { isApproving = false }

        do {
            let receipt = try await administrationClient.approve(currentDevice)
            guard requestID == discoveryRequestID,
                  discoveredDevices.contains(where: {
                      $0.id == currentDevice.id && $0.trustState == .unconfigured
                  })
            else { return false }
            guard receipt.deviceID == currentDevice.id else {
                throw DeviceAdministrationError.unexpectedResponse
            }

            let approvedDevice = HouseholdDevice(
                id: currentDevice.id,
                displayName: currentDevice.displayName,
                kind: currentDevice.kind,
                trustState: .approved
            )
            approvedDevices.append(approvedDevice)
            discoveredDevices.removeAll { $0.id == currentDevice.id }
            connectionStates.removeValue(forKey: currentDevice.id)
            setupStatuses[currentDevice.id] = .pending
            statusMessage = "\(currentDevice.displayName) approved. Setup is incomplete and the Device remains inactive."
            return true
        } catch let error as DeviceAdministrationError {
            guard requestID == discoveryRequestID else { return false }
            errorMessage = error.userMessage
            return false
        } catch {
            guard requestID == discoveryRequestID else { return false }
            errorMessage = DeviceAdministrationError.approvalFailed.userMessage
            return false
        }
    }

    @discardableResult
    func reEnroll(_ device: HouseholdDevice) async -> Bool {
        guard !isReenrolling else { return false }
        guard let currentDevice = approvedDevices.first(where: { $0.id == device.id }),
              setupStatus(for: currentDevice) == .revoked
        else {
            errorMessage = "This Device must be revoked before it can be re-enrolled."
            return false
        }

        isReenrolling = true
        errorMessage = nil
        statusMessage = nil
        let requestID = discoveryRequestID
        defer { isReenrolling = false }

        do {
            let receipt = try await administrationClient.reEnroll(currentDevice)
            guard requestID == discoveryRequestID,
                  approvedDevices.contains(where: { $0.id == currentDevice.id }),
                  setupStatus(for: currentDevice) == .revoked
            else {
                return false
            }
            guard receipt.deviceID == currentDevice.id else {
                throw DeviceAdministrationError.unexpectedResponse
            }

            // A new credential is not a Ready state. The caller must open the
            // ordered Room -> Wake Mappings -> Ready flow explicitly.
            statusMessage = "\(currentDevice.displayName) re-enrollment approved. Complete Room, Wake Mapping, and Ready setup."
            return true
        } catch is CancellationError {
            return false
        } catch let error as DeviceAdministrationError {
            guard requestID == discoveryRequestID else { return false }
            errorMessage = reenrollmentErrorMessage(for: error)
            return false
        } catch {
            guard requestID == discoveryRequestID else { return false }
            errorMessage = reenrollmentErrorMessage(for: .reEnrollmentFailed)
            return false
        }
    }

    func connect(to device: HouseholdDevice) async {
        guard !isDiscovering else {
            errorMessage = DeviceDiscoveryError.discoveryInProgress.userMessage
            return
        }
        guard let currentDevice = discoveredDevices.first(where: { $0.id == device.id }),
              currentDevice.trustState == .unconfigured
        else {
            errorMessage = DeviceDiscoveryError.deviceNotFound.userMessage
            return
        }

        errorMessage = nil
        statusMessage = nil
        isManualFallbackAvailable = false
        let requestID = discoveryRequestID
        connectionStates[currentDevice.id] = .connecting

        do {
            let receipt = try await client.connect(to: currentDevice)
            guard requestID == discoveryRequestID,
                  discoveredDevices.contains(where: {
                      $0.id == currentDevice.id && $0.trustState == .unconfigured
                  })
            else { return }
            guard receipt.deviceID == currentDevice.id else {
                throw DeviceDiscoveryError.unexpectedResponse
            }
            connectionStates[currentDevice.id] = .connected
            isManualFallbackAvailable = false
            statusMessage = "\(currentDevice.displayName) responded. It remains unconfigured."
        } catch let error as DeviceDiscoveryError {
            guard requestID == discoveryRequestID else { return }
            connectionStates[currentDevice.id] = .failed(error)
            errorMessage = error.userMessage
            isManualFallbackAvailable = client.supportsManualPairing
                && (error == .connectionFailed || error == .lanUnavailable)
        } catch {
            guard requestID == discoveryRequestID else { return }
            connectionStates[currentDevice.id] = .failed(.connectionFailed)
            errorMessage = DeviceDiscoveryError.connectionFailed.userMessage
            isManualFallbackAvailable = client.supportsManualPairing
        }
    }

    private func setupStatus(for state: DeviceConfigurationState) -> DeviceSetupStatus {
        switch state.identityStatus {
        case .verificationRequired:
            return state.homeEligibility?.allowsOperation == false
                ? .unavailable
                : .verificationRequired
        case .verified:
            if state.homeEligibility?.allowsOperation == false {
                return .unavailable
            }
            return state.pendingConfiguration == nil ? .ready : .updatePending
        case .unavailable:
            return .unavailable
        case .revocationPending:
            return .revocationPending
        case .revoked:
            return .revoked
        }
    }

    private func verifyConfiguredDevices(
        _ devices: [HouseholdDevice],
        requestID: Int
    ) async {
        guard !isVerifying else { return }
        isVerifying = true
        defer { isVerifying = false }

        for device in devices {
            guard requestID == discoveryRequestID else { return }
            await verifyConfiguredDevice(device, requestID: requestID)
        }
    }

    private func verifyConfiguredDevice(
        _ device: HouseholdDevice,
        requestID: Int
    ) async {
        guard requestID == discoveryRequestID,
              let currentDevice = approvedDevices.first(where: { $0.id == device.id }),
              let state = configurationStates[device.id],
              state.homeEligibility?.allowsOperation != false,
              state.identityStatus != .revocationPending,
              state.identityStatus != .revoked
        else {
            return
        }

        do {
            let receipt = try await administrationClient.verify(
                currentDevice,
                against: state.verifiedConfiguration
            )
            guard requestID == discoveryRequestID,
                  approvedDevices.contains(where: { $0.id == device.id })
            else {
                return
            }
            guard receipt.deviceID == device.id else {
                throw DeviceAdministrationError.unexpectedResponse
            }

            switch receipt.status {
            case .verified:
                guard receipt.matches(state.verifiedConfiguration) else {
                    throw DeviceAdministrationError.unexpectedResponse
                }
                await applyIdentityStatus(.verified, to: state)
                statusMessage = "\(device.displayName) is verified and ready."
            case .unavailable:
                await applyIdentityStatus(.unavailable, to: state)
                errorMessage = verificationFailureMessage
                statusMessage = "\(device.displayName) is unavailable and remains inactive."
            case .revocationPending:
                await applyIdentityStatus(.revocationPending, to: state)
                errorMessage = "Device access revocation is still pending. It remains inactive until confirmed."
                statusMessage = "\(device.displayName) remains inactive while access revocation is pending."
            case .revoked:
                await applyIdentityStatus(.revoked, to: state)
                errorMessage = nil
                statusMessage = "Device access is revoked. Explicit re-enrollment is required."
            case .verificationRequired:
                throw DeviceAdministrationError.unexpectedResponse
            }
        } catch is CancellationError {
            return
        } catch let error as DeviceAdministrationError {
            guard requestID == discoveryRequestID else { return }
            await applyIdentityStatus(.unavailable, to: state)
            errorMessage = verificationFailureMessage(for: error)
            statusMessage = "\(device.displayName) remains inactive until its identity is verified."
        } catch {
            guard requestID == discoveryRequestID else { return }
            await applyIdentityStatus(.unavailable, to: state)
            errorMessage = verificationFailureMessage
            statusMessage = "\(device.displayName) remains inactive until its identity is verified."
        }
    }

    private func applyIdentityStatus(
        _ identityStatus: DeviceIdentityStatus,
        to state: DeviceConfigurationState
    ) async {
        var updatedState = state
        updatedState.identityStatus = identityStatus
        configurationStates[state.deviceID] = updatedState
        setupStatuses[state.deviceID] = setupStatus(for: updatedState)
        try? await configurationStore.save(updatedState)
    }

    private var verificationFailureMessage: String {
        "The Device identity could not be verified. It remains unavailable until verification succeeds."
    }

    private func verificationFailureMessage(for error: DeviceAdministrationError) -> String {
        switch error {
        case .unexpectedResponse, .transportUnavailable:
            verificationFailureMessage
        case .approvalFailed, .configurationFailed:
            verificationFailureMessage
        case .revocationFailed, .reEnrollmentFailed:
            verificationFailureMessage
        }
    }

    private func reenrollmentErrorMessage(for error: DeviceAdministrationError) -> String {
        switch error {
        case .reEnrollmentFailed, .transportUnavailable, .unexpectedResponse:
            "The Device could not be re-enrolled. It remains unavailable. Try again."
        case .approvalFailed, .configurationFailed, .revocationFailed:
            "The Device could not be re-enrolled. It remains unavailable. Try again."
        }
    }

    private func loadSetupDrafts() async -> String? {
        do {
            let drafts = try await draftStore.loadAll()
            setupDrafts = drafts.reduce(into: [:]) { result, draft in
                result[draft.deviceID] = draft
            }
            return nil
        } catch {
            setupDrafts = [:]
            return "Saved Device setup drafts could not be loaded. Try again."
        }
    }

    private func loadConfigurationStates() async -> String? {
        do {
            configurationStates = try await configurationStore.loadAll().reduce(
                into: [String: DeviceConfigurationState]()
            ) { states, state in
                var state = state
                // A receipt from a previous process cannot prove that the
                // Device or its mapped Profiles are still usable today.
                // Preserve revoked/unavailable last-known state, but always
                // re-check a previously verified state after reload.
                if state.identityStatus == .verified {
                    state.identityStatus = .verificationRequired
                }
                states[state.deviceID] = state
                setupStatuses[state.deviceID] = setupStatus(for: state)
            }
            return nil
        } catch {
            configurationStates = [:]
            return "Saved Device configuration state could not be loaded. Try again."
        }
    }
}

@MainActor
@Observable
final class DeviceSetupModel {
    let device: HouseholdDevice
    private let administrationClient: any DeviceAdministrationClient
    private let draftStore: any DeviceSetupDraftStore
    private let configurationStore: any DeviceConfigurationStore
    private let homeServiceClient: (any HomeServiceClient)?

    private(set) var step: DeviceSetupStep = .room
    private(set) var errorMessage: String?
    private(set) var homeStatusMessage: String?
    private(set) var homeConfigurationRevision: Int?
    private(set) var homeRooms: [HomeRoom] = []
    private(set) var homeMappingCatalog: [CanonicalWakeMapping] = []
    private(set) var isPublishing = false
    private(set) var isActive = false
    private(set) var hasDraft = false
    private(set) var isLoadingDraft = false
    private(set) var isSavingDraft = false
    private var didLoadDraft = false
    var room = ""
    var wakeMappings: [DeviceWakeMapping] = []

    private(set) var isHomeBacked: Bool

    private var homeSnapshot: HomeConfigurationSnapshot?
    private var homeDeviceConfiguration: DeviceSetupConfiguration?

    init(
        device: HouseholdDevice,
        administrationClient: any DeviceAdministrationClient,
        draftStore: any DeviceSetupDraftStore = NoopDeviceSetupDraftStore(),
        configurationStore: any DeviceConfigurationStore = NoopDeviceConfigurationStore(),
        homeServiceClient: (any HomeServiceClient)? = nil
    ) {
        self.device = device
        self.administrationClient = administrationClient
        self.draftStore = draftStore
        self.configurationStore = configurationStore
        self.homeServiceClient = homeServiceClient
        self.isHomeBacked = homeServiceClient != nil
    }

    func loadDraft() async {
        guard !didLoadDraft else { return }
        didLoadDraft = true
        isLoadingDraft = true
        defer { isLoadingDraft = false }

        do {
            let draft = try await draftStore.load(for: device.id)
            if let homeServiceClient,
               try await homeServiceClient.hasApprovedRoute() {
                isHomeBacked = true
                let snapshot = try await homeServiceClient.fetchConfiguration()
                guard snapshot.isCompleteHomeSnapshot else {
                    throw HomeServiceError.invalidResponse
                }
                homeSnapshot = snapshot
                homeConfigurationRevision = snapshot.revision
                homeRooms = snapshot.rooms
                homeMappingCatalog = snapshot.wakeMappings
                guard let homeDevice = snapshot.devices.first(where: {
                    $0.deviceID == device.id
                }) else {
                    errorMessage = HomeServiceError.notFound.userMessage
                    throw HomeServiceError.notFound
                }
                homeDeviceConfiguration = homeDevice
                guard homeDevice.wakeClaimEnabled else {
                    errorMessage = "Home has disabled wake claims for this Device. It cannot become Ready."
                    homeStatusMessage = errorMessage
                    return
                }
                // Home owns the canonical mappings. A local draft may retain
                // the Room selection, but it cannot redefine the catalog.
                if let draft {
                    room = draft.room
                    step = draft.step == .complete ? .ready : draft.step
                    hasDraft = true
                } else {
                    room = homeDevice.room
                    wakeMappings = homeDevice.wakeMappings
                    step = .room
                }
                if draft != nil {
                    wakeMappings = homeDevice.wakeMappings
                }
            } else {
                isHomeBacked = false
                if let draft {
                    room = draft.room
                    wakeMappings = draft.wakeMappings
                    step = draft.step == .complete ? .ready : draft.step
                    hasDraft = true
                }
            }
            errorMessage = nil
        } catch let error as HomeServiceError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "The saved Device setup draft could not be loaded. Try again."
        }
    }

    @discardableResult
    func preserveDraft() async -> Bool {
        guard step != .complete else { return true }
        guard !isSavingDraft else { return false }

        isSavingDraft = true
        defer { isSavingDraft = false }
        let draft = DeviceSetupDraft(
            deviceID: device.id,
            room: isHomeBacked
                ? room
                : room.trimmingCharacters(in: .whitespacesAndNewlines),
            wakeMappings: normalizedWakeMappings,
            step: step
        )

        do {
            try await draftStore.save(draft)
            hasDraft = true
            return true
        } catch {
            errorMessage = "The Device setup draft could not be saved. Try again."
            return false
        }
    }

    @discardableResult
    func discardDraft() async -> Bool {
        guard !isSavingDraft else { return false }

        isSavingDraft = true
        defer { isSavingDraft = false }

        do {
            try await draftStore.delete(deviceID: device.id)
            room = ""
            wakeMappings = []
            step = .room
            hasDraft = false
            errorMessage = nil
            return true
        } catch {
            errorMessage = "The Device setup draft could not be discarded. Try again."
            return false
        }
    }

    @discardableResult
    func continueFromRoom() -> Bool {
        if isHomeBacked {
            guard let homeSnapshot else {
                errorMessage = "Home Rooms could not be loaded. Reload before continuing."
                return false
            }
            if let exactRoom = homeSnapshot.rooms.first(where: { $0.id == room }) {
                room = exactRoom.id
                errorMessage = nil
                step = .wakeMappings
                return true
            }
            let normalizedRoom = room.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedRoom.isEmpty else {
                errorMessage = "Assign this Device to a Room."
                return false
            }
            let foldedRoom = normalizedRoom.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard let homeRoom = homeSnapshot.rooms.first(where: { room in
                room.id == normalizedRoom
                    || room.name.folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: Locale(identifier: "en_US_POSIX")
                    ) == foldedRoom
            }) else {
                errorMessage = "Home does not have that Room. Choose an existing Home Room."
                return false
            }
            room = homeRoom.id
        } else {
            let normalizedRoom = room.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedRoom.isEmpty else {
                errorMessage = "Assign this Device to a Room."
                return false
            }
            room = normalizedRoom
        }

        errorMessage = nil
        step = .wakeMappings
        return true
    }

    func addWakeMapping() {
        guard !isHomeBacked else {
            errorMessage = "Home owns the household Wake Mapping catalog. It cannot be edited on this Device."
            return
        }
        wakeMappings.append(DeviceWakeMapping())
        errorMessage = nil
    }

    func removeWakeMapping(id: UUID) {
        guard !isHomeBacked else {
            errorMessage = "Home owns the household Wake Mapping catalog. It cannot be edited on this Device."
            return
        }
        wakeMappings.removeAll { $0.id == id }
        errorMessage = nil
    }

    func editWakeMappings() {
        guard step == .ready, !isHomeBacked else { return }
        step = .wakeMappings
        errorMessage = nil
    }

    func returnToRoom() {
        guard step == .wakeMappings else { return }
        step = .room
        errorMessage = nil
    }

    @discardableResult
    func continueFromMappings() -> Bool {
        if let validationMessage = setupValidationMessage() {
            errorMessage = validationMessage
            return false
        }

        wakeMappings = wakeMappings.map { mapping in
            var normalized = mapping
            normalized.wakePhrase = mapping.wakePhrase.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !isHomeBacked {
                normalized.profileIdentifier = mapping.normalizedProfileIdentifier
            }
            return normalized
        }
        errorMessage = nil
        step = .ready
        return true
    }

    func confirmReady() async -> Bool {
        guard step == .ready, !isPublishing else { return false }
        if let validationMessage = setupValidationMessage() {
            errorMessage = validationMessage
            return false
        }

        isPublishing = true
        errorMessage = nil
        defer { isPublishing = false }

        let configuration = DeviceSetupConfiguration(
            deviceID: device.id,
            room: isHomeBacked
                ? room
                : room.trimmingCharacters(in: .whitespacesAndNewlines),
            wakeMappings: normalizedWakeMappings
        )

        do {
            let activeConfiguration: DeviceSetupConfiguration
            if isHomeBacked {
                guard let homeServiceClient else {
                    throw HomeServiceError.notConfigured
                }
                activeConfiguration = try await publishToHome(
                    configuration,
                    using: homeServiceClient
                )
                let receipt = try await administrationClient.verify(
                    device,
                    against: activeConfiguration
                )
                guard receipt.deviceID == device.id,
                      receipt.matches(activeConfiguration) else {
                    throw DeviceAdministrationError.unexpectedResponse
                }
                guard receipt.status == .verified else {
                    throw DeviceAdministrationError.unexpectedResponse
                }
            } else {
                let receipt = try await administrationClient.configure(configuration)
                guard receipt.matches(configuration) else {
                    throw DeviceAdministrationError.unexpectedResponse
                }
                activeConfiguration = configuration
            }

            try await configurationStore.save(
                DeviceConfigurationState(
                    approvedDevice: device,
                    verifiedConfiguration: activeConfiguration,
                    pendingConfiguration: nil,
                    homeConfigurationRevision: homeConfigurationRevision,
                    homeEligibility: isHomeBacked ? .eligible : nil,
                    identityStatus: .verified
                )
            )

            do {
                try await draftStore.delete(deviceID: device.id)
                hasDraft = false
            } catch {
                hasDraft = true
                errorMessage = "Device is ready, but its saved setup draft could not be cleared."
            }
            isActive = true
            step = .complete
            return true
        } catch let error as HomeServiceError {
            homeStatusMessage = error.userMessage
            errorMessage = error.userMessage
            return false
        } catch let error as DeviceAdministrationError {
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = DeviceAdministrationError.configurationFailed.userMessage
            return false
        }
    }

    private func publishToHome(
        _ configuration: DeviceSetupConfiguration,
        using homeServiceClient: any HomeServiceClient
    ) async throws -> DeviceSetupConfiguration {
        let currentSnapshot = try await homeServiceClient.fetchConfiguration()
        guard currentSnapshot.isCompleteHomeSnapshot else {
            throw HomeServiceError.invalidResponse
        }
        homeConfigurationRevision = currentSnapshot.revision

        guard let homeDevice = currentSnapshot.devices.first(where: {
            $0.deviceID == configuration.deviceID
        }) else {
            throw HomeServiceError.notFound
        }
        guard homeDevice.wakeClaimEnabled else {
            throw HomeServiceError.invalidConfiguration
        }

        guard let candidate = currentSnapshot.replacingDevice(
            configuration,
            preservingHomeMetadata: true
        ),
        candidate.isCompleteHomeSnapshot,
        let candidateDevice = candidate.devices.first(where: {
            $0.deviceID == configuration.deviceID
        }) else {
            throw HomeServiceError.invalidConfiguration
        }

        let publishedSnapshot = try await homeServiceClient.publish(
            candidate,
            expectedRevision: currentSnapshot.revision
        )
        guard publishedSnapshot.matchesCandidate(
            candidate,
            minimumRevision: currentSnapshot.revision
        ),
        let publishedDevice = publishedSnapshot.devices.first(where: {
            $0.deviceID == configuration.deviceID
        }),
        DeviceConfigurationReceipt(
            deviceID: publishedDevice.deviceID,
            configuration: publishedDevice,
            homeConfigurationRevision: publishedSnapshot.revision
        ).matches(
            candidateDevice,
            minimumHomeRevision: currentSnapshot.revision
        ) else {
            throw HomeServiceError.invalidResponse
        }

        homeSnapshot = publishedSnapshot
        homeConfigurationRevision = publishedSnapshot.revision
        homeStatusMessage = "Home configuration published at revision \(publishedSnapshot.revision)."
        return publishedDevice
    }

    private var normalizedWakeMappings: [DeviceWakeMapping] {
        wakeMappings.map { mapping in
            var normalized = mapping
            normalized.wakePhrase = mapping.wakePhrase.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !isHomeBacked {
                normalized.profileIdentifier = mapping.normalizedProfileIdentifier
            }
            return normalized
        }
    }

    private func setupValidationMessage() -> String? {
        if isHomeBacked {
            guard let homeSnapshot,
                  homeSnapshot.rooms.contains(where: { $0.id == room }) else {
                return "Choose an existing Home Room."
            }
        } else if room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Assign this Device to a Room."
        }
        guard !wakeMappings.isEmpty else {
            return isHomeBacked
                ? "Home has no Wake Mappings for this Device. Add a mapping to Home's canonical catalog before continuing."
                : "Add at least one Wake Mapping."
        }
        guard wakeMappings.allSatisfy(\.hasValidValues) else {
            return "Each Wake Mapping needs a wake phrase and Hermes Profile identifier."
        }

        var seenPhrases = Set<String>()
        guard wakeMappings.allSatisfy({ seenPhrases.insert($0.normalizedWakePhrase).inserted }) else {
            return "Each Wake Mapping must use a unique wake phrase."
        }

        let profiles = Set(wakeMappings.map(\.normalizedProfileIdentifier))
        guard profiles.count == 1 else {
            return "A Device must use exactly one Hermes Profile identifier."
        }

        if let homeDeviceConfiguration {
            guard homeDeviceConfiguration.wakeClaimEnabled else {
                return "Home has disabled wake claims for this Device. It cannot become Ready."
            }
            let mappingsMatchHome = wakeMappings.count == homeDeviceConfiguration.wakeMappings.count
                && zip(wakeMappings, homeDeviceConfiguration.wakeMappings).allSatisfy { local, home in
                    local.canonicalID == home.canonicalID
                        && local.normalizedWakePhrase == home.normalizedWakePhrase
                        && local.normalizedProfileIdentifier == home.normalizedProfileIdentifier
                }
            guard mappingsMatchHome else {
                return "Home owns the canonical Wake Mapping catalog. Reload before continuing."
            }
            if let homeProfile = homeDeviceConfiguration.profileIdentifier,
               profiles.first != homeProfile.trimmingCharacters(in: .whitespacesAndNewlines) {
                return "This Device is assigned to a different Hermes Profile by Home."
            }
        }
        return nil
    }
}

@MainActor
@Observable
final class DeviceConfigurationModel {
    let device: HouseholdDevice
    private let administrationClient: any DeviceAdministrationClient
    private let configurationStore: any DeviceConfigurationStore
    private let homeServiceClient: (any HomeServiceClient)?

    private(set) var verifiedConfiguration: DeviceSetupConfiguration
    private(set) var pendingConfiguration: DeviceSetupConfiguration?
    private(set) var publicationStatus: DeviceConfigurationPublicationStatus = .verified
    private(set) var errorMessage: String?
    private(set) var homeStatusMessage: String?
    private(set) var homeConfigurationRevision: Int?
    private(set) var homeRooms: [HomeRoom] = []
    private(set) var homeMappingCatalog: [CanonicalWakeMapping] = []
    private(set) var isPublishing = false
    private(set) var isRevoking = false
    private(set) var isActive = false
    private(set) var identityStatus: DeviceIdentityStatus = .verificationRequired
    private(set) var homeEligibility: HomeDeviceEligibility?
    private(set) var isHomeBacked: Bool
    private var didLoad = false

    var room: String
    var wakeMappings: [DeviceWakeMapping]

    init(
        device: HouseholdDevice,
        administrationClient: any DeviceAdministrationClient,
        configurationStore: any DeviceConfigurationStore = NoopDeviceConfigurationStore(),
        homeServiceClient: (any HomeServiceClient)? = nil
    ) {
        self.device = device
        self.administrationClient = administrationClient
        self.configurationStore = configurationStore
        self.homeServiceClient = homeServiceClient
        self.isHomeBacked = homeServiceClient != nil
        self.verifiedConfiguration = DeviceSetupConfiguration(
            deviceID: device.id,
            room: "",
            wakeMappings: []
        )
        self.room = ""
        self.wakeMappings = []
    }

    func load() async {
        guard !didLoad else { return }
        didLoad = true

        do {
            guard let state = try await configurationStore.load(for: device.id) else {
                errorMessage = "The verified Device configuration is unavailable."
                return
            }
            verifiedConfiguration = state.verifiedConfiguration
            pendingConfiguration = state.pendingConfiguration
            homeConfigurationRevision = state.homeConfigurationRevision
            homeEligibility = state.homeEligibility
            isHomeBacked = state.homeEligibility != nil
                || state.homeConfigurationRevision != nil
            let editableConfiguration = state.pendingConfiguration ?? state.verifiedConfiguration
            room = editableConfiguration.room
            wakeMappings = editableConfiguration.wakeMappings
            publicationStatus = state.pendingConfiguration == nil ? .verified : .pending
            identityStatus = state.identityStatus
            isActive = state.identityStatus.isOperational
                && (!isHomeBacked || homeEligibility?.allowsOperation == true)
            errorMessage = nil
            if let homeServiceClient {
                if isHomeBacked {
                    isActive = false
                    _ = await reloadHomeConfiguration()
                } else {
                    do {
                        if try await homeServiceClient.hasApprovedRoute() {
                            isHomeBacked = true
                            homeEligibility = .unavailable
                            isActive = false
                            _ = await reloadHomeConfiguration()
                        } else {
                            isHomeBacked = false
                            isActive = identityStatus.isOperational
                        }
                    } catch {
                        isHomeBacked = true
                        homeEligibility = .unavailable
                        isActive = false
                        homeStatusMessage = HomeServiceError.invalidEndpoint.userMessage
                        _ = await persistCurrentState()
                    }
                }
            } else if isHomeBacked {
                homeEligibility = .unavailable
                isActive = false
                homeStatusMessage = HomeServiceError.notConfigured.userMessage
                _ = await persistCurrentState()
            }
        } catch {
            errorMessage = "The verified Device configuration could not be loaded."
        }
    }

    @discardableResult
    func reloadHomeConfiguration() async -> Bool {
        guard let homeServiceClient else {
            homeEligibility = .unavailable
            isActive = false
            homeStatusMessage = HomeServiceError.notConfigured.userMessage
            _ = await persistCurrentState()
            return false
        }

        do {
            let snapshot = try await homeServiceClient.fetchConfiguration()
            guard snapshot.isCompleteHomeSnapshot else {
                throw HomeServiceError.invalidResponse
            }
            homeSnapshot = snapshot
            homeConfigurationRevision = snapshot.revision
            homeRooms = snapshot.rooms
            homeMappingCatalog = snapshot.wakeMappings

            guard let homeDevice = snapshot.devices.first(where: {
                $0.deviceID == device.id
            }) else {
                homeEligibility = .ineligible
                identityStatus = .verificationRequired
                isActive = false
                homeStatusMessage = "Home no longer lists this Device. It remains inactive."
                errorMessage = HomeServiceError.notFound.userMessage
                return await persistCurrentState()
            }

            let projectionChanged = !DeviceConfigurationReceipt(
                deviceID: homeDevice.deviceID,
                configuration: homeDevice
            ).matches(verifiedConfiguration)
            verifiedConfiguration = homeDevice
            homeEligibility = homeDevice.wakeClaimEnabled ? .eligible : .ineligible
            var roomResetAfterCatalogChange = false
            if let existingPending = pendingConfiguration {
                let pendingRoomIsStillHomeOwned = snapshot.rooms.contains {
                    $0.id == existingPending.room
                }
                let rebasedRoom = pendingRoomIsStillHomeOwned
                    ? existingPending.room
                    : homeDevice.room
                roomResetAfterCatalogChange = !pendingRoomIsStillHomeOwned
                    && existingPending.room != rebasedRoom
                let rebasedPending = DeviceSetupConfiguration(
                    deviceID: homeDevice.deviceID,
                    room: rebasedRoom,
                    wakeMappings: homeDevice.wakeMappings,
                    arbitrationPriority: homeDevice.arbitrationPriority,
                    displayName: homeDevice.displayName,
                    profileIdentifier: homeDevice.profileIdentifier,
                    wakeClaimEnabled: homeDevice.wakeClaimEnabled
                )
                pendingConfiguration = rebasedPending
                room = rebasedRoom
                wakeMappings = homeDevice.wakeMappings
                publicationStatus = .pending
            } else {
                room = homeDevice.room
                wakeMappings = homeDevice.wakeMappings
                publicationStatus = .verified
            }

            if !homeDevice.wakeClaimEnabled {
                identityStatus = .verificationRequired
                isActive = false
            } else if projectionChanged, identityStatus == .verified {
                // Home configuration is not a Device identity proof. A
                // changed projection must be checked by the Device seam again
                // before it can become operational.
                identityStatus = .verificationRequired
                isActive = false
            } else {
                isActive = identityStatus.isOperational
                    && homeEligibility?.allowsOperation == true
            }
            homeStatusMessage = roomResetAfterCatalogChange
                ? "Home configuration changed and the previous Room is no longer available. The Device now uses its current Home Room."
                : "Home configuration revision \(snapshot.revision) loaded."
            return await persistCurrentState()
        } catch let error as HomeServiceError {
            homeEligibility = .unavailable
            isActive = false
            homeStatusMessage = error.userMessage
            _ = await persistCurrentState()
            return false
        } catch {
            homeEligibility = .unavailable
            isActive = false
            homeStatusMessage = HomeServiceError.transportUnavailable.userMessage
            _ = await persistCurrentState()
            return false
        }
    }

    func publish() async -> Bool {
        guard !isPublishing else { return false }
        guard !isHomeBacked || homeEligibility?.allowsOperation == true else {
            errorMessage = homeEligibility == .ineligible
                ? "Home has disabled wake claims for this Device. It cannot be updated."
                : "Home availability must be confirmed before updating this Device. Reload Home configuration."
            return false
        }
        guard identityStatus.isOperational else {
            switch identityStatus {
            case .revoked:
                errorMessage = "Device access is revoked. Explicit re-enrollment is required."
            case .revocationPending:
                errorMessage = "Device access revocation is pending. It remains unavailable until you retry."
            case .verificationRequired, .unavailable, .verified:
                errorMessage = "The Device identity could not be verified. Verify the Device before updating its mappings."
            }
            return false
        }
        guard let configuration = validatedConfiguration() else { return false }

        isPublishing = true
        errorMessage = nil
        defer { isPublishing = false }
        let usesHomeService = isHomeBacked

        pendingConfiguration = configuration
        publicationStatus = .pending
        do {
            try await configurationStore.save(
                DeviceConfigurationState(
                    approvedDevice: device,
                    verifiedConfiguration: verifiedConfiguration,
                    pendingConfiguration: configuration,
                    homeConfigurationRevision: homeConfigurationRevision,
                    homeEligibility: homeEligibility,
                    identityStatus: identityStatus
                )
            )
            let activeConfiguration: DeviceSetupConfiguration
            if isHomeBacked {
                guard let homeServiceClient else {
                    throw HomeServiceError.notConfigured
                }
                activeConfiguration = try await publishToHome(
                    configuration,
                    using: homeServiceClient
                )
                let verification = try await administrationClient.verify(
                    device,
                    against: activeConfiguration
                )
                guard verification.deviceID == device.id,
                      verification.status == .verified,
                      verification.matches(activeConfiguration) else {
                    throw DeviceAdministrationError.unexpectedResponse
                }
            } else {
                let receipt = try await administrationClient.configure(configuration)
                guard receipt.matches(configuration) else {
                    throw DeviceAdministrationError.unexpectedResponse
                }
                activeConfiguration = configuration
            }
            let completedState = DeviceConfigurationState(
                approvedDevice: device,
                verifiedConfiguration: activeConfiguration,
                pendingConfiguration: nil,
                homeConfigurationRevision: homeConfigurationRevision,
                homeEligibility: isHomeBacked ? .eligible : nil,
                identityStatus: .verified
            )
            do {
                try await configurationStore.save(completedState)
            } catch {
                isActive = false
                errorMessage = "The Device was published and verified, but its local receipt could not be saved. Reload before continuing."
                return false
            }
            verifiedConfiguration = activeConfiguration
            pendingConfiguration = nil
            publicationStatus = .verified
            identityStatus = .verified
            homeEligibility = completedState.homeEligibility
            isActive = true
            return true
        } catch let error as HomeServiceError {
            if error == .revisionConflict || error == .invalidResponse {
                homeSnapshot = nil
                homeConfigurationRevision = nil
            }
            _ = await persistCurrentState()
            homeStatusMessage = error.userMessage
            errorMessage = error.userMessage
            return false
        } catch let error as DeviceAdministrationError {
            if usesHomeService {
                identityStatus = .unavailable
                isActive = false
                _ = await persistCurrentState()
            }
            errorMessage = publicationErrorMessage(for: error)
            return false
        } catch {
            errorMessage = "The pending mapping edit could not be saved. The current verified mapping remains active."
            return false
        }
    }

    @discardableResult
    func revoke() async -> Bool {
        guard !isRevoking else { return false }
        guard identityStatus != .revoked else {
            errorMessage = "Device access is already revoked. Explicit re-enrollment is required."
            return false
        }
        isRevoking = true
        defer { isRevoking = false }

        let pendingState = DeviceConfigurationState(
            approvedDevice: device,
            verifiedConfiguration: verifiedConfiguration,
            pendingConfiguration: pendingConfiguration,
            homeConfigurationRevision: homeConfigurationRevision,
            homeEligibility: homeEligibility,
            identityStatus: .revocationPending
        )
        do {
            // Fail closed locally before asking the remote authority to
            // revoke. A transport failure must never leave a powered Device
            // looking Ready in the next launch.
            identityStatus = .revocationPending
            isActive = false
            try await configurationStore.save(pendingState)
        } catch {
            errorMessage = "Disconnect could not be prepared. The Device remains unavailable until you retry."
            return false
        }

        do {
            let receipt = try await administrationClient.revoke(device)
            guard receipt.deviceID == device.id else {
                throw DeviceAdministrationError.unexpectedResponse
            }

            identityStatus = .revoked
            isActive = false
            pendingConfiguration = nil
            publicationStatus = .verified
            try await configurationStore.save(
                DeviceConfigurationState(
                    approvedDevice: device,
                    verifiedConfiguration: verifiedConfiguration,
                    pendingConfiguration: nil,
                    homeConfigurationRevision: homeConfigurationRevision,
                    homeEligibility: homeEligibility,
                    identityStatus: .revoked
                )
            )
            errorMessage = nil
            return true
        } catch let error as DeviceAdministrationError {
            errorMessage = revocationErrorMessage(for: error)
            return false
        } catch {
            errorMessage = "Device access could not be confirmed. It remains unavailable until you retry."
            return false
        }
    }

    func removeWakeMapping(id: UUID) {
        guard !isHomeBacked else {
            errorMessage = "Home owns the household Wake Mapping catalog. It cannot be edited on this Device."
            return
        }
        wakeMappings.removeAll { $0.id == id }
        errorMessage = nil
    }

    func preservePending() async -> Bool {
        guard identityStatus.isOperational else {
            // Revoked and revocation-pending Devices cannot accumulate a new
            // mapping edit while their access boundary is inactive.
            return true
        }
        let configuration = normalizedConfiguration()
        guard configuration != verifiedConfiguration else {
            guard pendingConfiguration != nil else { return true }
            do {
                try await configurationStore.save(
                    DeviceConfigurationState(
                        approvedDevice: device,
                        verifiedConfiguration: verifiedConfiguration,
                        pendingConfiguration: nil,
                        homeConfigurationRevision: homeConfigurationRevision,
                        homeEligibility: homeEligibility,
                        identityStatus: identityStatus
                    )
                )
                pendingConfiguration = nil
                publicationStatus = .verified
                errorMessage = nil
                return true
            } catch {
                errorMessage = "The pending mapping edit could not be cleared. Try again."
                return false
            }
        }

        do {
            try await configurationStore.save(
                DeviceConfigurationState(
                    approvedDevice: device,
                    verifiedConfiguration: verifiedConfiguration,
                    pendingConfiguration: configuration,
                    homeConfigurationRevision: homeConfigurationRevision,
                    homeEligibility: homeEligibility,
                    identityStatus: identityStatus
                )
            )
            pendingConfiguration = configuration
            publicationStatus = .pending
            return true
        } catch {
            errorMessage = "The pending mapping edit could not be saved. Try again."
            return false
        }
    }

    private func validatedConfiguration() -> DeviceSetupConfiguration? {
        let normalizedRoom = room.trimmingCharacters(in: .whitespacesAndNewlines)
        if isHomeBacked {
            guard let homeSnapshot,
                  homeSnapshot.rooms.contains(where: { $0.id == room }) else {
                errorMessage = "Choose an existing Home Room."
                return nil
            }
        } else if normalizedRoom.isEmpty {
            errorMessage = "Assign this Device to a Room."
            return nil
        }
        guard !wakeMappings.isEmpty else {
            errorMessage = isHomeBacked
                ? "Home has no Wake Mappings for this Device. Add a mapping to Home's canonical catalog before continuing."
                : "Add at least one Wake Mapping."
            return nil
        }
        guard wakeMappings.allSatisfy(\.hasValidValues) else {
            errorMessage = "Each Wake Mapping needs a wake phrase and Hermes Profile identifier."
            return nil
        }

        var seenPhrases = Set<String>()
        guard wakeMappings.allSatisfy({
            seenPhrases.insert($0.normalizedWakePhrase).inserted
        }) else {
            errorMessage = "Each Wake Mapping must use a unique wake phrase."
            return nil
        }

        let profiles = Set(wakeMappings.map(\.normalizedProfileIdentifier))
        guard profiles.count == 1 else {
            errorMessage = "A Device must use exactly one Hermes Profile identifier."
            return nil
        }

        if isHomeBacked, let homeSnapshot {
            guard let homeDevice = homeSnapshot.devices.first(where: {
                $0.deviceID == device.id
            }) else {
                errorMessage = HomeServiceError.notFound.userMessage
                return nil
            }
            guard homeDevice.wakeClaimEnabled else {
                errorMessage = "Home has disabled wake claims for this Device. It cannot be updated."
                return nil
            }
            guard wakeMappings.count == homeDevice.wakeMappings.count,
                  zip(wakeMappings, homeDevice.wakeMappings).allSatisfy({ local, home in
                      local.canonicalID == home.canonicalID
                          && local.normalizedWakePhrase == home.normalizedWakePhrase
                          && local.normalizedProfileIdentifier == home.normalizedProfileIdentifier
                  }) else {
                errorMessage = "Home owns the canonical Wake Mapping catalog. Reload before publishing."
                return nil
            }
        }

        return normalizedConfiguration(room: isHomeBacked ? room : normalizedRoom)
    }

    private func normalizedConfiguration(
        room normalizedRoom: String? = nil
    ) -> DeviceSetupConfiguration {
        let homeDevice = homeSnapshot?.devices.first { $0.deviceID == device.id }
        let metadata = isHomeBacked ? homeDevice : verifiedConfiguration
        return DeviceSetupConfiguration(
            deviceID: device.id,
            room: normalizedRoom ?? (isHomeBacked
                ? room
                : room.trimmingCharacters(in: .whitespacesAndNewlines)),
            wakeMappings: wakeMappings.map { mapping in
                var normalized = mapping
                normalized.wakePhrase = mapping.wakePhrase.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if !isHomeBacked {
                    normalized.profileIdentifier = mapping.normalizedProfileIdentifier
                }
                return normalized
            },
            arbitrationPriority: metadata?.arbitrationPriority,
            displayName: metadata?.displayName,
            profileIdentifier: metadata?.profileIdentifier,
            wakeClaimEnabled: metadata?.wakeClaimEnabled ?? true
        )
    }

    private var homeSnapshot: HomeConfigurationSnapshot?

    @discardableResult
    private func persistCurrentState() async -> Bool {
        do {
            try await configurationStore.save(
                DeviceConfigurationState(
                    approvedDevice: device,
                    verifiedConfiguration: verifiedConfiguration,
                    pendingConfiguration: pendingConfiguration,
                    homeConfigurationRevision: homeConfigurationRevision,
                    homeEligibility: homeEligibility,
                    identityStatus: identityStatus
                )
            )
            return true
        } catch {
            isActive = false
            errorMessage = "Home eligibility could not be saved locally. The Device remains inactive until you reload."
            homeStatusMessage = errorMessage
            return false
        }
    }

    private func publishToHome(
        _ configuration: DeviceSetupConfiguration,
        using homeServiceClient: any HomeServiceClient
    ) async throws -> DeviceSetupConfiguration {
        // Re-read immediately before the atomic replacement. A cached
        // revision is useful for display, never for a write precondition.
        let currentSnapshot = try await homeServiceClient.fetchConfiguration()
        guard currentSnapshot.isCompleteHomeSnapshot else {
            throw HomeServiceError.invalidResponse
        }
        homeSnapshot = currentSnapshot
        homeConfigurationRevision = currentSnapshot.revision

        guard let candidate = currentSnapshot.replacingDevice(
            configuration,
            preservingHomeMetadata: true
        ),
        candidate.isCompleteHomeSnapshot,
        let candidateDevice = candidate.devices.first(where: {
            $0.deviceID == configuration.deviceID
        }) else {
            throw HomeServiceError.invalidConfiguration
        }

        let publishedSnapshot = try await homeServiceClient.publish(
            candidate,
            expectedRevision: currentSnapshot.revision
        )
        guard publishedSnapshot.matchesCandidate(
            candidate,
            minimumRevision: currentSnapshot.revision
        ),
        let publishedDevice = publishedSnapshot.devices.first(where: {
            $0.deviceID == configuration.deviceID
        }),
        DeviceConfigurationReceipt(
            deviceID: publishedDevice.deviceID,
            configuration: publishedDevice,
            homeConfigurationRevision: publishedSnapshot.revision
        ).matches(
            candidateDevice,
            minimumHomeRevision: currentSnapshot.revision
        ) else {
            throw HomeServiceError.invalidResponse
        }

        homeSnapshot = publishedSnapshot
        homeConfigurationRevision = publishedSnapshot.revision
        homeStatusMessage = "Home configuration published at revision \(publishedSnapshot.revision)."
        return publishedDevice
    }

    private func publicationErrorMessage(for error: DeviceAdministrationError) -> String {
        switch error {
        case .unexpectedResponse:
            return "The Device identity could not be verified. Try again."
        case .approvalFailed, .configurationFailed, .revocationFailed, .reEnrollmentFailed, .transportUnavailable:
            return "The mapping edit could not be published. The current verified mapping remains active."
        }
    }

    private func revocationErrorMessage(for error: DeviceAdministrationError) -> String {
        switch error {
        case .revocationFailed, .reEnrollmentFailed, .transportUnavailable, .unexpectedResponse:
            return "Device access could not be confirmed. It remains unavailable until you retry."
        case .approvalFailed, .configurationFailed:
            return "Device access could not be confirmed. It remains unavailable until you retry."
        }
    }
}
