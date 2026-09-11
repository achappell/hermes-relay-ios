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
    private(set) var errorMessage: String?
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
            await verifyConfiguredDevices(approved, requestID: requestID)
        } catch is CancellationError {
            return
        } catch let error as DeviceDiscoveryError {
            guard discoveryRequestID == requestID else { return }
            errorMessage = discoveryMessage(for: error)
            isManualFallbackAvailable = error == .lanUnavailable
                && client.supportsManualPairing
        } catch {
            guard discoveryRequestID == requestID else { return }
            errorMessage = "Device discovery failed. Try again."
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
            return .verificationRequired
        case .verified:
            return state.pendingConfiguration == nil ? .ready : .updatePending
        case .unavailable:
            return .unavailable
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

    private(set) var step: DeviceSetupStep = .room
    private(set) var errorMessage: String?
    private(set) var isPublishing = false
    private(set) var isActive = false
    private(set) var hasDraft = false
    private(set) var isLoadingDraft = false
    private(set) var isSavingDraft = false
    private var didLoadDraft = false
    var room = ""
    var wakeMappings: [DeviceWakeMapping] = []

    init(
        device: HouseholdDevice,
        administrationClient: any DeviceAdministrationClient,
        draftStore: any DeviceSetupDraftStore = NoopDeviceSetupDraftStore(),
        configurationStore: any DeviceConfigurationStore = NoopDeviceConfigurationStore()
    ) {
        self.device = device
        self.administrationClient = administrationClient
        self.draftStore = draftStore
        self.configurationStore = configurationStore
    }

    func loadDraft() async {
        guard !didLoadDraft else { return }
        didLoadDraft = true
        isLoadingDraft = true
        defer { isLoadingDraft = false }

        do {
            guard let draft = try await draftStore.load(for: device.id) else {
                return
            }
            room = draft.room
            wakeMappings = draft.wakeMappings
            step = draft.step == .complete ? .ready : draft.step
            hasDraft = true
            errorMessage = nil
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
            room: room.trimmingCharacters(in: .whitespacesAndNewlines),
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
        let normalizedRoom = room.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRoom.isEmpty else {
            errorMessage = "Assign this Device to a Room."
            return false
        }

        room = normalizedRoom
        errorMessage = nil
        step = .wakeMappings
        return true
    }

    func addWakeMapping() {
        wakeMappings.append(DeviceWakeMapping())
        errorMessage = nil
    }

    func removeWakeMapping(id: UUID) {
        wakeMappings.removeAll { $0.id == id }
        errorMessage = nil
    }

    func editWakeMappings() {
        guard step == .ready else { return }
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
            normalized.profileIdentifier = mapping.normalizedProfileIdentifier
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
            room: room.trimmingCharacters(in: .whitespacesAndNewlines),
            wakeMappings: normalizedWakeMappings
        )

        do {
            let receipt = try await administrationClient.configure(configuration)
            guard receipt.matches(configuration) else {
                throw DeviceAdministrationError.unexpectedResponse
            }

            try? await configurationStore.save(
                DeviceConfigurationState(
                    approvedDevice: device,
                    verifiedConfiguration: configuration,
                    pendingConfiguration: nil,
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
        } catch let error as DeviceAdministrationError {
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = DeviceAdministrationError.configurationFailed.userMessage
            return false
        }
    }

    private var normalizedWakeMappings: [DeviceWakeMapping] {
        wakeMappings.map { mapping in
            var normalized = mapping
            normalized.wakePhrase = mapping.wakePhrase.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            normalized.profileIdentifier = mapping.normalizedProfileIdentifier
            return normalized
        }
    }

    private func setupValidationMessage() -> String? {
        let normalizedRoom = room.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRoom.isEmpty else {
            return "Assign this Device to a Room."
        }
        guard !wakeMappings.isEmpty else {
            return "Add at least one Wake Mapping."
        }
        guard wakeMappings.allSatisfy(\.hasValidValues) else {
            return "Each Wake Mapping needs a wake phrase and Hermes Profile identifier."
        }

        var seenPhrases = Set<String>()
        guard wakeMappings.allSatisfy({ seenPhrases.insert($0.normalizedWakePhrase).inserted }) else {
            return "Each Wake Mapping must use a unique wake phrase."
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

    private(set) var verifiedConfiguration: DeviceSetupConfiguration
    private(set) var pendingConfiguration: DeviceSetupConfiguration?
    private(set) var publicationStatus: DeviceConfigurationPublicationStatus = .verified
    private(set) var errorMessage: String?
    private(set) var isPublishing = false
    private(set) var isActive = false
    private(set) var identityStatus: DeviceIdentityStatus = .verificationRequired
    private var didLoad = false

    var room: String
    var wakeMappings: [DeviceWakeMapping]

    init(
        device: HouseholdDevice,
        administrationClient: any DeviceAdministrationClient,
        configurationStore: any DeviceConfigurationStore = NoopDeviceConfigurationStore()
    ) {
        self.device = device
        self.administrationClient = administrationClient
        self.configurationStore = configurationStore
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
            let editableConfiguration = state.pendingConfiguration ?? state.verifiedConfiguration
            room = editableConfiguration.room
            wakeMappings = editableConfiguration.wakeMappings
            publicationStatus = state.pendingConfiguration == nil ? .verified : .pending
            identityStatus = state.identityStatus
            isActive = state.identityStatus.isOperational
            errorMessage = nil
        } catch {
            errorMessage = "The verified Device configuration could not be loaded."
        }
    }

    func publish() async -> Bool {
        guard !isPublishing else { return false }
        guard identityStatus.isOperational else {
            errorMessage = identityStatus == .revoked
                ? "Device access is revoked. Explicit re-enrollment is required."
                : "The Device identity could not be verified. Verify the Device before updating its mappings."
            return false
        }
        guard let configuration = validatedConfiguration() else { return false }

        isPublishing = true
        errorMessage = nil
        defer { isPublishing = false }

        pendingConfiguration = configuration
        publicationStatus = .pending
        do {
            try await configurationStore.save(
                DeviceConfigurationState(
                    approvedDevice: device,
                    verifiedConfiguration: verifiedConfiguration,
                    pendingConfiguration: configuration,
                    identityStatus: identityStatus
                )
            )
            let receipt = try await administrationClient.configure(configuration)
            guard receipt.matches(configuration) else {
                throw DeviceAdministrationError.unexpectedResponse
            }
            verifiedConfiguration = configuration
            pendingConfiguration = nil
            publicationStatus = .verified
            identityStatus = .verified
            isActive = true
            try? await configurationStore.save(
                DeviceConfigurationState(
                    approvedDevice: device,
                    verifiedConfiguration: configuration,
                    pendingConfiguration: nil,
                    identityStatus: .verified
                )
            )
            return true
        } catch let error as DeviceAdministrationError {
            errorMessage = publicationErrorMessage(for: error)
            return false
        } catch {
            errorMessage = "The pending mapping edit could not be saved. The current verified mapping remains active."
            return false
        }
    }

    func removeWakeMapping(id: UUID) {
        wakeMappings.removeAll { $0.id == id }
        errorMessage = nil
    }

    func preservePending() async -> Bool {
        let configuration = normalizedConfiguration()
        guard configuration != verifiedConfiguration else {
            guard pendingConfiguration != nil else { return true }
            do {
                try await configurationStore.save(
                    DeviceConfigurationState(
                        approvedDevice: device,
                        verifiedConfiguration: verifiedConfiguration,
                        pendingConfiguration: nil,
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
        guard !normalizedRoom.isEmpty else {
            errorMessage = "Assign this Device to a Room."
            return nil
        }
        guard !wakeMappings.isEmpty else {
            errorMessage = "Add at least one Wake Mapping."
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

        return normalizedConfiguration(room: normalizedRoom)
    }

    private func normalizedConfiguration(
        room normalizedRoom: String? = nil
    ) -> DeviceSetupConfiguration {
        DeviceSetupConfiguration(
            deviceID: device.id,
            room: normalizedRoom
                ?? room.trimmingCharacters(in: .whitespacesAndNewlines),
            wakeMappings: wakeMappings.map { mapping in
                var normalized = mapping
                normalized.wakePhrase = mapping.wakePhrase.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                normalized.profileIdentifier = mapping.normalizedProfileIdentifier
                return normalized
            }
        )
    }

    private func publicationErrorMessage(for error: DeviceAdministrationError) -> String {
        switch error {
        case .unexpectedResponse:
            return "The Device identity could not be verified. Try again."
        case .approvalFailed, .configurationFailed, .transportUnavailable:
            return "The mapping edit could not be published. The current verified mapping remains active."
        }
    }
}
