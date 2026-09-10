import Foundation
import Observation

@MainActor
@Observable
final class DeviceDiscoveryModel {
    private(set) var approvedDevices: [HouseholdDevice] = []
    private(set) var discoveredDevices: [HouseholdDevice] = []
    private(set) var isApproving = false
    private(set) var isDiscovering = false
    private(set) var errorMessage: String?
    private(set) var isManualFallbackAvailable = false
    private(set) var statusMessage: String?
    var manualIdentifier = ""
    private(set) var isPairingManually = false
    private var connectionStates: [String: DeviceConnectionState] = [:]
    private var setupStatuses: [String: DeviceSetupStatus] = [:]
    private var discoveryRequestID = 0

    private let client: any DeviceDiscoveryClient
    private let administrationClient: any DeviceAdministrationClient

    init(
        client: any DeviceDiscoveryClient,
        administrationClient: any DeviceAdministrationClient = UnavailableDeviceAdministrationClient()
    ) {
        self.client = client
        self.administrationClient = administrationClient
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
            let locallyApproved = approvedDevices.filter {
                setupStatuses[$0.id] != nil
            }
            let approved = uniqueDevices(
                snapshot.approvedDevices + locallyApproved,
                withTrustState: .approved
            )
            let approvedIDs = Set(approved.map(\.id))
            let discovered = uniqueDevices(
                snapshot.unconfiguredDevices,
                withTrustState: .unconfigured
            ).filter { !approvedIDs.contains($0.id) }

            errorMessage = nil
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
        setupStatuses[device.id]
    }

    func approvedDevice(for device: HouseholdDevice) -> HouseholdDevice? {
        approvedDevices.first { $0.id == device.id }
    }

    func isActive(_ device: HouseholdDevice) -> Bool {
        setupStatuses[device.id]?.isActive == true
    }

    func markReady(_ device: HouseholdDevice) {
        guard setupStatuses[device.id] == .pending else { return }
        setupStatuses[device.id] = .ready
        statusMessage = "\(device.displayName) is ready and active."
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
}

@MainActor
@Observable
final class DeviceSetupModel {
    let device: HouseholdDevice
    private let administrationClient: any DeviceAdministrationClient

    private(set) var step: DeviceSetupStep = .room
    private(set) var errorMessage: String?
    private(set) var isPublishing = false
    private(set) var isActive = false
    var room = ""
    var wakeMappings: [DeviceWakeMapping] = []

    init(
        device: HouseholdDevice,
        administrationClient: any DeviceAdministrationClient
    ) {
        self.device = device
        self.administrationClient = administrationClient
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
            guard receipt.deviceID == device.id else {
                throw DeviceAdministrationError.unexpectedResponse
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
