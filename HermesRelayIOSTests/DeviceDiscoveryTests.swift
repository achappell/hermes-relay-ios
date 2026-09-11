import XCTest
#if os(iOS)
import SwiftUI
import UIKit
#endif
@testable import HermesRelayIOS

@MainActor
final class DeviceDiscoveryTests: XCTestCase {
    func testDebugFixtureProvidesMixedDevicesAndDeterministicConnectionOutcomes() async throws {
        let client = DeviceDiscoveryClientFactory.make(
            arguments: [DeviceDiscoveryClientFactory.fixtureLaunchArgument]
        )

        let snapshot = try await client.discover()

        XCTAssertEqual(snapshot.approvedDevices.map(\.id), ["approved-kitchen-display"])
        XCTAssertEqual(
            snapshot.unconfiguredDevices.map(\.id),
            ["unconfigured-hallway-puck", "unconfigured-study-display"]
        )

        let successfulReceipt = try await client.connect(to: snapshot.unconfiguredDevices[0])
        XCTAssertEqual(successfulReceipt.deviceID, "unconfigured-hallway-puck")

        do {
            _ = try await client.connect(to: snapshot.unconfiguredDevices[1])
            XCTFail("The second fixture candidate should exercise the failure state")
        } catch let error as DeviceDiscoveryError {
            XCTAssertEqual(error, .connectionFailed)
        }
    }

    func testDeviceDiscoveryFactoryDefaultsToUnavailableWithoutFixtureArgument() async {
        let client = DeviceDiscoveryClientFactory.make(arguments: [])

        do {
            _ = try await client.discover()
            XCTFail("The shipped default must not claim to discover Devices")
        } catch let error as DeviceDiscoveryError {
            XCTAssertEqual(error, .lanUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeviceAdministrationFactoryDefaultsToUnavailableWithoutFixtureArgument() async {
        let client = DeviceAdministrationClientFactory.make(arguments: [])
        let device = HouseholdDevice(
            id: "unconfigured-puck",
            displayName: "New Puck",
            kind: .puck,
            trustState: .unconfigured
        )

        do {
            _ = try await client.approve(device)
            XCTFail("The shipped default must not claim to approve Devices")
        } catch let error as DeviceAdministrationError {
            XCTAssertEqual(error, .transportUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeviceSetupDraftStoreRoundTripsDraftByDeviceID() async throws {
        let fileURL = temporaryDraftFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceSetupDraftStore(fileURL: fileURL)
        let draft = DeviceSetupDraft(
            deviceID: "approved-puck",
            room: "Hallway",
            wakeMappings: [
                DeviceWakeMapping(
                    wakePhrase: "Hey Missy",
                    profileIdentifier: "missy"
                )
            ],
            step: .ready
        )

        try await store.save(draft)
        let loaded = try await store.load(for: draft.deviceID)

        XCTAssertEqual(loaded, draft)
    }

    func testDeviceSetupDraftStoreReplacesMatchingDeviceAndRetainsOthers() async throws {
        let fileURL = temporaryDraftFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceSetupDraftStore(fileURL: fileURL)
        let first = DeviceSetupDraft(
            deviceID: "approved-puck",
            room: "Kitchen",
            wakeMappings: [],
            step: .room
        )
        let second = DeviceSetupDraft(
            deviceID: "second-device",
            room: "Study",
            wakeMappings: [],
            step: .room
        )
        let replacement = DeviceSetupDraft(
            deviceID: first.deviceID,
            room: "Hallway",
            wakeMappings: [],
            step: .wakeMappings
        )

        try await store.save(first)
        try await store.save(second)
        try await store.save(replacement)

        let loaded = try await store.loadAll()
        let loadedFirst = try await store.load(for: first.deviceID)
        let loadedSecond = try await store.load(for: second.deviceID)

        XCTAssertEqual(loaded.map(\.deviceID), ["approved-puck", "second-device"])
        XCTAssertEqual(loadedFirst, replacement)
        XCTAssertEqual(loadedSecond, second)
    }

    func testDeviceSetupDraftStoreDeletesOnlyRequestedDraft() async throws {
        let fileURL = temporaryDraftFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceSetupDraftStore(fileURL: fileURL)
        let first = DeviceSetupDraft(
            deviceID: "approved-puck",
            room: "Kitchen",
            wakeMappings: [],
            step: .room
        )
        let second = DeviceSetupDraft(
            deviceID: "second-device",
            room: "Study",
            wakeMappings: [],
            step: .room
        )

        try await store.save(first)
        try await store.save(second)
        try await store.delete(deviceID: first.deviceID)

        let deleted = try await store.load(for: first.deviceID)
        let remaining = try await store.load(for: second.deviceID)
        XCTAssertNil(deleted)
        XCTAssertEqual(remaining, second)
    }

    func testDeviceSetupDraftSurvivesCancelAndResumesAtLastStep() async throws {
        let fileURL = temporaryDraftFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceSetupDraftStore(fileURL: fileURL)
        let mapping = DeviceWakeMapping(
            wakePhrase: "Hey Missy",
            profileIdentifier: "missy"
        )
        let first = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient(),
            draftStore: store
        )
        await first.loadDraft()
        first.room = " Hallway "
        XCTAssertTrue(first.continueFromRoom())
        first.wakeMappings = [mapping]
        XCTAssertTrue(first.continueFromMappings())

        let preserved = await first.preserveDraft()
        XCTAssertTrue(preserved)

        let resumed = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient(),
            draftStore: store
        )
        await resumed.loadDraft()

        XCTAssertTrue(resumed.hasDraft)
        XCTAssertEqual(resumed.step, .ready)
        XCTAssertEqual(resumed.room, "Hallway")
        XCTAssertEqual(resumed.wakeMappings, [mapping])
        XCTAssertFalse(resumed.isActive)
    }

    func testDiscardedDeviceSetupDraftDoesNotResume() async throws {
        let fileURL = temporaryDraftFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceSetupDraftStore(fileURL: fileURL)
        let setup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient(),
            draftStore: store
        )
        setup.room = "Hallway"
        let preserved = await setup.preserveDraft()
        XCTAssertTrue(preserved)

        let discarded = await setup.discardDraft()
        XCTAssertTrue(discarded)

        let resumed = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient(),
            draftStore: store
        )
        await resumed.loadDraft()

        XCTAssertFalse(resumed.hasDraft)
        XCTAssertEqual(resumed.step, .room)
        XCTAssertTrue(resumed.room.isEmpty)
        XCTAssertTrue(resumed.wakeMappings.isEmpty)
        XCTAssertFalse(resumed.isActive)
    }

    func testSuccessfulDeviceSetupRemovesSavedDraftAndBecomesActive() async throws {
        let fileURL = temporaryDraftFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceSetupDraftStore(fileURL: fileURL)
        let setup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient(),
            draftStore: store
        )
        setup.room = "Kitchen"
        XCTAssertTrue(setup.continueFromRoom())
        setup.wakeMappings = [
            DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
        ]
        XCTAssertTrue(setup.continueFromMappings())
        let preserved = await setup.preserveDraft()
        XCTAssertTrue(preserved)

        let completed = await setup.confirmReady()

        XCTAssertTrue(completed)
        XCTAssertTrue(setup.isActive)
        XCTAssertEqual(setup.step, .complete)
        XCTAssertFalse(setup.hasDraft)
        let deleted = try await store.load(for: setup.device.id)
        XCTAssertNil(deleted)
    }

    func testDiscoveryRehydratesSavedDraftAsPendingWithoutPromotingUnconfiguredDevice() async throws {
        let fileURL = temporaryDraftFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceSetupDraftStore(fileURL: fileURL)
        let approved = approvedSetupDevice
        try await store.save(
            DeviceSetupDraft(
                deviceID: approved.id,
                room: "Kitchen",
                wakeMappings: [],
                step: .room
            )
        )
        let unexpectedUnconfigured = HouseholdDevice(
            id: "unconfigured-puck",
            displayName: "New Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [approved],
                unconfiguredDevices: [unexpectedUnconfigured]
            )
        )
        let model = DeviceDiscoveryModel(
            client: client,
            draftStore: store
        )

        await model.discover()

        XCTAssertEqual(model.approvedDevices, [approved])
        XCTAssertEqual(model.discoveredDevices, [unexpectedUnconfigured])
        XCTAssertEqual(model.setupStatus(for: approved), .pending)
        XCTAssertTrue(model.hasSetupDraft(for: approved))
        XCTAssertFalse(model.isActive(approved))
    }

    func testDiscoveryShowsActiveDeviceWithPendingMappingEditAsUpdatePending() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "Kitchen",
            wakeMappings: [
                DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
            ]
        )
        let pending = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "Kitchen",
            wakeMappings: [
                DeviceWakeMapping(wakePhrase: "Hey Jensen", profileIdentifier: "jensen")
            ]
        )
        try await store.save(
            DeviceConfigurationState(
                verifiedConfiguration: verified,
                pendingConfiguration: pending
            )
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [approvedSetupDevice],
                unconfiguredDevices: []
            )
        )
        let administrationClient = FakeDeviceAdministrationClient()
        let model = DeviceDiscoveryModel(
            client: client,
            administrationClient: administrationClient,
            configurationStore: store
        )

        await model.discover()

        XCTAssertEqual(model.setupStatus(for: approvedSetupDevice), .updatePending)
        XCTAssertTrue(model.isActive(approvedSetupDevice))
    }

    func testPersistedConfigurationRequiresFreshVerificationBeforeShowingReady() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = kitchenConfiguration(for: approvedSetupDevice)
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: verified,
                pendingConfiguration: nil,
                identityStatus: .verified
            )
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [approvedSetupDevice],
                unconfiguredDevices: []
            )
        )
        let administrationClient = FakeDeviceAdministrationClient(
            verificationError: .transportUnavailable
        )
        let model = DeviceDiscoveryModel(
            client: client,
            administrationClient: administrationClient,
            configurationStore: store
        )

        await model.discover()

        XCTAssertEqual(model.setupStatus(for: approvedSetupDevice), .unavailable)
        XCTAssertFalse(model.isActive(approvedSetupDevice))
        XCTAssertEqual(
            model.errorMessage,
            "The Device identity could not be verified. It remains unavailable until verification succeeds."
        )
        let verificationCount = await administrationClient.verificationCount()
        XCTAssertEqual(verificationCount, 1)
    }

    func testExactVerificationReceiptRestoresReadyState() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = kitchenConfiguration(for: approvedSetupDevice)
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: verified,
                pendingConfiguration: nil,
                identityStatus: .verificationRequired
            )
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [approvedSetupDevice],
                unconfiguredDevices: []
            )
        )
        let administrationClient = FakeDeviceAdministrationClient(
            verificationConfiguration: verified
        )
        let model = DeviceDiscoveryModel(
            client: client,
            administrationClient: administrationClient,
            configurationStore: store
        )

        await model.discover()

        XCTAssertEqual(model.setupStatus(for: approvedSetupDevice), .ready)
        XCTAssertTrue(model.isActive(approvedSetupDevice))
        XCTAssertNil(model.errorMessage)
        let persisted = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(persisted?.identityStatus, .verified)
    }

    func testUnavailableVerificationDoesNotFallBackToAnotherProfile() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let unavailable = approvedSetupDevice
        let available = HouseholdDevice(
            id: "approved-study-puck",
            displayName: "Study Puck",
            kind: .puck,
            trustState: .approved
        )
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: unavailable,
                verifiedConfiguration: kitchenConfiguration(for: unavailable),
                pendingConfiguration: nil,
                identityStatus: .verificationRequired
            )
        )
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: available,
                verifiedConfiguration: kitchenConfiguration(for: available),
                pendingConfiguration: nil,
                identityStatus: .verificationRequired
            )
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [unavailable, available],
                unconfiguredDevices: []
            )
        )
        let administrationClient = FakeDeviceAdministrationClient(
            verificationStatusByDeviceID: [unavailable.id: .unavailable]
        )
        let model = DeviceDiscoveryModel(
            client: client,
            administrationClient: administrationClient,
            configurationStore: store
        )

        await model.discover()

        XCTAssertEqual(model.setupStatus(for: unavailable), .unavailable)
        XCTAssertFalse(model.isActive(unavailable))
        XCTAssertEqual(model.setupStatus(for: available), .ready)
        XCTAssertTrue(model.isActive(available))
        let persistedUnavailableState = try await store.load(for: unavailable.id)
        XCTAssertEqual(
            persistedUnavailableState?.verifiedConfiguration.wakeMappings.first?.profileIdentifier,
            "missy"
        )
    }

    func testRevokedVerificationRemainsRevokedWhenDeviceIsReachable() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = kitchenConfiguration(for: approvedSetupDevice)
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: verified,
                pendingConfiguration: nil,
                identityStatus: .verificationRequired
            )
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [approvedSetupDevice],
                unconfiguredDevices: []
            )
        )
        let administrationClient = FakeDeviceAdministrationClient(
            verificationStatus: .revoked
        )
        let model = DeviceDiscoveryModel(
            client: client,
            administrationClient: administrationClient,
            configurationStore: store
        )

        await model.discover()
        await model.verify(approvedSetupDevice)

        XCTAssertEqual(model.setupStatus(for: approvedSetupDevice), .revoked)
        XCTAssertFalse(model.isActive(approvedSetupDevice))
        XCTAssertEqual(
            model.statusMessage,
            "Device access is revoked. Explicit re-enrollment is required."
        )
        let persistedRevokedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(persistedRevokedState?.identityStatus, .revoked)
    }

    func testReachableRevokedDeviceDoesNotSilentlyReactivate() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: kitchenConfiguration(for: approvedSetupDevice),
                pendingConfiguration: nil,
                identityStatus: .revoked
            )
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [approvedSetupDevice],
                unconfiguredDevices: []
            )
        )
        let administrationClient = FakeDeviceAdministrationClient()
        let model = DeviceDiscoveryModel(
            client: client,
            administrationClient: administrationClient,
            configurationStore: store
        )

        await model.discover()

        XCTAssertEqual(model.setupStatus(for: approvedSetupDevice), .revoked)
        XCTAssertFalse(model.isActive(approvedSetupDevice))
        let verificationCount = await administrationClient.verificationCount()
        XCTAssertEqual(verificationCount, 0)
    }

    func testMismatchedVerificationReceiptFailsClosed() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = kitchenConfiguration(for: approvedSetupDevice)
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: verified,
                pendingConfiguration: nil,
                identityStatus: .verificationRequired
            )
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [approvedSetupDevice],
                unconfiguredDevices: []
            )
        )
        let administrationClient = FakeDeviceAdministrationClient(
            verificationConfiguration: DeviceSetupConfiguration(
                deviceID: approvedSetupDevice.id,
                room: "Study",
                wakeMappings: [
                    DeviceWakeMapping(wakePhrase: "Hey Jensen", profileIdentifier: "jensen")
                ]
            )
        )
        let model = DeviceDiscoveryModel(
            client: client,
            administrationClient: administrationClient,
            configurationStore: store
        )

        await model.discover()

        XCTAssertEqual(model.setupStatus(for: approvedSetupDevice), .unavailable)
        XCTAssertFalse(model.isActive(approvedSetupDevice))
        XCTAssertEqual(
            model.errorMessage,
            "The Device identity could not be verified. It remains unavailable until verification succeeds."
        )
    }

    func testDiscoveryRehydratesSavedConfigurationWhenAdapterReportsDeviceAsUnconfigured() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "Kitchen",
            wakeMappings: [
                DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
            ]
        )
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: verified,
                pendingConfiguration: nil
            )
        )
        let adapterCandidate = HouseholdDevice(
            id: approvedSetupDevice.id,
            displayName: "Kitchen Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [],
                unconfiguredDevices: [adapterCandidate]
            )
        )
        let administrationClient = FakeDeviceAdministrationClient()
        let model = DeviceDiscoveryModel(
            client: client,
            administrationClient: administrationClient,
            configurationStore: store
        )

        await model.discover()

        XCTAssertEqual(model.approvedDevices, [approvedSetupDevice])
        XCTAssertTrue(model.discoveredDevices.isEmpty)
        XCTAssertEqual(model.setupStatus(for: approvedSetupDevice), .ready)
    }

    func testDiscoveryMigratesLegacyConfigurationUsingMatchingAdapterIdentity() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "Kitchen",
            wakeMappings: [
                DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
            ]
        )
        try await store.save(
            DeviceConfigurationState(
                verifiedConfiguration: verified,
                pendingConfiguration: nil
            )
        )
        let adapterCandidate = HouseholdDevice(
            id: approvedSetupDevice.id,
            displayName: "Kitchen Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [],
                unconfiguredDevices: [adapterCandidate]
            )
        )
        let model = DeviceDiscoveryModel(
            client: client,
            configurationStore: store
        )

        await model.discover()

        XCTAssertEqual(model.approvedDevices, [approvedSetupDevice])
        XCTAssertTrue(model.discoveredDevices.isEmpty)
    }

    func testApprovalRequiresAConfirmedConnectionAndKeepsCandidateUnapproved() async {
        let candidate = HouseholdDevice(
            id: "unconfigured-puck",
            displayName: "New Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let discoveryClient = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [],
                unconfiguredDevices: [candidate]
            )
        )
        let administrationClient = FakeDeviceAdministrationClient()
        let model = DeviceDiscoveryModel(
            client: discoveryClient,
            administrationClient: administrationClient
        )
        await model.discover()

        let approved = await model.approve(candidate)

        XCTAssertFalse(approved)
        XCTAssertEqual(
            model.errorMessage,
            "Confirm the Device connection before approving it."
        )
        XCTAssertTrue(model.approvedDevices.isEmpty)
        XCTAssertEqual(model.discoveredDevices, [candidate])
        let approvalCount = await administrationClient.approvalCount()
        XCTAssertEqual(approvalCount, 0)
    }

    func testApprovalMovesConnectedCandidateToAuthorizedSetupPendingState() async {
        let candidate = HouseholdDevice(
            id: "unconfigured-puck",
            displayName: "New Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let discoveryClient = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [],
                unconfiguredDevices: [candidate]
            )
        )
        let administrationClient = FakeDeviceAdministrationClient()
        let model = DeviceDiscoveryModel(
            client: discoveryClient,
            administrationClient: administrationClient
        )
        await model.discover()
        await model.connect(to: candidate)

        let approved = await model.approve(candidate)

        XCTAssertTrue(approved)
        XCTAssertEqual(
            model.approvedDevices,
            [
                HouseholdDevice(
                    id: candidate.id,
                    displayName: candidate.displayName,
                    kind: candidate.kind,
                    trustState: .approved
                )
            ]
        )
        XCTAssertTrue(model.discoveredDevices.isEmpty)
        XCTAssertEqual(model.setupStatus(for: candidate), .pending)
        XCTAssertFalse(model.isActive(candidate))
        let approvalCount = await administrationClient.approvalCount()
        XCTAssertEqual(approvalCount, 1)
    }

    func testMismatchedApprovalReceiptFailsClosedWithoutPromotion() async {
        let candidate = HouseholdDevice(
            id: "unconfigured-puck",
            displayName: "New Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let discoveryClient = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [],
                unconfiguredDevices: [candidate]
            )
        )
        let administrationClient = FakeDeviceAdministrationClient(
            approvalReceiptDeviceID: "different-device"
        )
        let model = DeviceDiscoveryModel(
            client: discoveryClient,
            administrationClient: administrationClient
        )
        await model.discover()
        await model.connect(to: candidate)

        let approved = await model.approve(candidate)

        XCTAssertFalse(approved)
        XCTAssertEqual(
            model.errorMessage,
            "The Device identity could not be verified. Try again."
        )
        XCTAssertTrue(model.approvedDevices.isEmpty)
        XCTAssertEqual(model.discoveredDevices, [candidate])
        XCTAssertNil(model.setupStatus(for: candidate))
    }

    func testSetupRequiresRoomAndAtLeastOneWakeMappingBeforeAdvancing() async {
        let setup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient()
        )

        XCTAssertFalse(setup.continueFromRoom())
        XCTAssertEqual(setup.step, .room)
        XCTAssertEqual(setup.errorMessage, "Assign this Device to a Room.")

        setup.room = "Kitchen"
        XCTAssertTrue(setup.continueFromRoom())
        XCTAssertEqual(setup.step, .wakeMappings)

        XCTAssertFalse(setup.continueFromMappings())
        XCTAssertEqual(setup.step, .wakeMappings)
        XCTAssertEqual(setup.errorMessage, "Add at least one Wake Mapping.")
    }

    func testSetupRejectsDuplicateWakePhrasesBeforePublishing() async {
        let administrationClient = FakeDeviceAdministrationClient()
        let setup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient
        )
        setup.room = "Kitchen"
        XCTAssertTrue(setup.continueFromRoom())
        setup.wakeMappings = [
            DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy"),
            DeviceWakeMapping(wakePhrase: " hey missy ", profileIdentifier: "other")
        ]

        XCTAssertFalse(setup.continueFromMappings())
        XCTAssertEqual(setup.step, .wakeMappings)
        XCTAssertEqual(
            setup.errorMessage,
            "Each Wake Mapping must use a unique wake phrase."
        )
        let configurationCount = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCount, 0)
    }

    func testValidSetupPublishesOnlyAfterReadyConfirmation() async {
        let administrationClient = FakeDeviceAdministrationClient()
        let setup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient
        )
        setup.room = "Kitchen"
        XCTAssertTrue(setup.continueFromRoom())
        let mapping = DeviceWakeMapping(
            wakePhrase: "Hey Missy",
            profileIdentifier: "missy"
        )
        setup.wakeMappings = [mapping]

        XCTAssertTrue(setup.continueFromMappings())
        XCTAssertEqual(setup.step, .ready)
        let configurationCountBeforePublish = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCountBeforePublish, 0)

        let completed = await setup.confirmReady()

        XCTAssertTrue(completed)
        XCTAssertEqual(setup.step, .complete)
        XCTAssertNil(setup.errorMessage)
        let configurationCountAfterPublish = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCountAfterPublish, 1)
        let lastConfiguration = await administrationClient.lastConfiguration()
        XCTAssertEqual(
            lastConfiguration,
            DeviceSetupConfiguration(
                deviceID: approvedSetupDevice.id,
                room: "Kitchen",
                wakeMappings: [mapping]
            )
        )
    }

    func testMismatchedConfigurationReceiptLeavesDeviceInactive() async {
        let administrationClient = FakeDeviceAdministrationClient(
            configurationReceiptDeviceID: "different-device"
        )
        let setup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient
        )
        setup.room = "Kitchen"
        XCTAssertTrue(setup.continueFromRoom())
        setup.wakeMappings = [
            DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
        ]
        XCTAssertTrue(setup.continueFromMappings())

        let completed = await setup.confirmReady()

        XCTAssertFalse(completed)
        XCTAssertEqual(setup.step, .ready)
        XCTAssertEqual(
            setup.errorMessage,
            "The Device identity could not be verified. Try again."
        )
        XCTAssertFalse(setup.isActive)
    }

    func testFailedConfigurationLeavesDeviceReadyAndInactive() async {
        let administrationClient = FakeDeviceAdministrationClient(
            configurationError: .configurationFailed
        )
        let setup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient
        )
        setup.room = "Kitchen"
        XCTAssertTrue(setup.continueFromRoom())
        setup.wakeMappings = [
            DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
        ]
        XCTAssertTrue(setup.continueFromMappings())

        let completed = await setup.confirmReady()

        XCTAssertFalse(completed)
        XCTAssertEqual(setup.step, .ready)
        XCTAssertEqual(
            setup.errorMessage,
            "The Device setup could not be saved. Try again."
        )
        XCTAssertFalse(setup.isActive)
        let configurationCount = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCount, 0)
    }

    func testReadyConfirmationRevalidatesSetupBeforePublishing() async {
        let administrationClient = FakeDeviceAdministrationClient()
        let setup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient
        )
        setup.room = "Kitchen"
        XCTAssertTrue(setup.continueFromRoom())
        setup.wakeMappings = [
            DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
        ]
        XCTAssertTrue(setup.continueFromMappings())
        setup.wakeMappings[0].wakePhrase = " "

        let completed = await setup.confirmReady()

        XCTAssertFalse(completed)
        XCTAssertEqual(setup.step, .ready)
        XCTAssertEqual(
            setup.errorMessage,
            "Each Wake Mapping needs a wake phrase and Hermes Profile identifier."
        )
        let configurationCount = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCount, 0)
    }

    func testFailedMappingPublishPreservesVerifiedConfigurationAndStoresPendingEdit() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "Kitchen",
            wakeMappings: [
                DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
            ]
        )
        try await store.save(
            DeviceConfigurationState(
                verifiedConfiguration: verified,
                pendingConfiguration: nil
            )
        )
        let administrationClient = FakeDeviceAdministrationClient(
            configurationError: .configurationFailed
        )
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store
        )
        await model.load()

        let pending = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "Kitchen",
            wakeMappings: [
                DeviceWakeMapping(wakePhrase: "Hey Jensen", profileIdentifier: "jensen")
            ]
        )
        model.wakeMappings = pending.wakeMappings

        let published = await model.publish()

        XCTAssertFalse(published)
        XCTAssertEqual(model.verifiedConfiguration, verified)
        XCTAssertEqual(model.pendingConfiguration, pending)
        XCTAssertEqual(model.publicationStatus, .pending)
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(
            model.errorMessage,
            "The mapping edit could not be published. The current verified mapping remains active."
        )
        let persistedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(persistedState?.pendingConfiguration, pending)
    }

    func testUnpublishedMappingEditCanBePreservedAsPendingWithoutPublishing() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "Kitchen",
            wakeMappings: [
                DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
            ]
        )
        try await store.save(
            DeviceConfigurationState(
                verifiedConfiguration: verified,
                pendingConfiguration: nil
            )
        )
        let administrationClient = FakeDeviceAdministrationClient()
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store
        )
        await model.load()
        model.wakeMappings = [
            DeviceWakeMapping(wakePhrase: "Hey Jensen", profileIdentifier: "jensen")
        ]

        let preserved = await model.preservePending()

        XCTAssertTrue(preserved)
        XCTAssertEqual(model.publicationStatus, .pending)
        let configurationCount = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCount, 0)
        let persistedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(
            persistedState?.pendingConfiguration?.wakeMappings.first?.profileIdentifier,
            "jensen"
        )
    }

    func testMismatchedMappingReceiptDoesNotPromotePendingEdit() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "Kitchen",
            wakeMappings: [
                DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
            ]
        )
        try await store.save(
            DeviceConfigurationState(
                verifiedConfiguration: verified,
                pendingConfiguration: nil
            )
        )
        let pending = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "Kitchen",
            wakeMappings: [
                DeviceWakeMapping(wakePhrase: "Hey Jensen", profileIdentifier: "jensen")
            ]
        )
        let administrationClient = FakeDeviceAdministrationClient(
            configurationReceipt: DeviceSetupConfiguration(
                deviceID: approvedSetupDevice.id,
                room: "Kitchen",
                wakeMappings: [
                    DeviceWakeMapping(wakePhrase: "Hey River", profileIdentifier: "river")
                ]
            )
        )
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store
        )
        await model.load()
        model.wakeMappings = pending.wakeMappings

        let published = await model.publish()

        XCTAssertFalse(published)
        XCTAssertEqual(model.verifiedConfiguration, verified)
        XCTAssertEqual(model.pendingConfiguration, pending)
        XCTAssertEqual(model.publicationStatus, .pending)
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(
            model.errorMessage,
            "The Device identity could not be verified. Try again."
        )
        let persistedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(persistedState?.verifiedConfiguration, verified)
        XCTAssertEqual(persistedState?.pendingConfiguration, pending)
    }

    func testRevertingPendingMappingToVerifiedClearsPendingEditWithoutPublishing() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "Kitchen",
            wakeMappings: [
                DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
            ]
        )
        let pending = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "Kitchen",
            wakeMappings: [
                DeviceWakeMapping(wakePhrase: "Hey Jensen", profileIdentifier: "jensen")
            ]
        )
        try await store.save(
            DeviceConfigurationState(
                verifiedConfiguration: verified,
                pendingConfiguration: pending
            )
        )
        let administrationClient = FakeDeviceAdministrationClient()
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store
        )
        await model.load()
        model.room = verified.room
        model.wakeMappings = verified.wakeMappings

        let preserved = await model.preservePending()

        XCTAssertTrue(preserved)
        XCTAssertEqual(model.publicationStatus, .verified)
        XCTAssertNil(model.pendingConfiguration)
        let configurationCount = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCount, 0)
        let persistedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(persistedState?.verifiedConfiguration, verified)
        XCTAssertNil(persistedState?.pendingConfiguration)
    }

    func testDuplicateMappingEditIsRejectedBeforePublishing() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "Kitchen",
            wakeMappings: [
                DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
            ]
        )
        try await store.save(
            DeviceConfigurationState(
                verifiedConfiguration: verified,
                pendingConfiguration: nil
            )
        )
        let administrationClient = FakeDeviceAdministrationClient()
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store
        )
        await model.load()
        model.wakeMappings = [
            DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy"),
            DeviceWakeMapping(wakePhrase: " hey missy ", profileIdentifier: "jensen")
        ]

        let published = await model.publish()

        XCTAssertFalse(published)
        XCTAssertEqual(
            model.errorMessage,
            "Each Wake Mapping must use a unique wake phrase."
        )
        XCTAssertEqual(model.publicationStatus, .verified)
        XCTAssertNil(model.pendingConfiguration)
        let configurationCount = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCount, 0)
    }

    func testSuccessfulMappingPublishPromotesExactProfileSpecificConfiguration() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "Kitchen",
            wakeMappings: [
                DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
            ]
        )
        try await store.save(
            DeviceConfigurationState(
                verifiedConfiguration: verified,
                pendingConfiguration: nil
            )
        )
        let administrationClient = FakeDeviceAdministrationClient()
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store
        )
        await model.load()
        let replacement = DeviceWakeMapping(
            wakePhrase: "Hey Jensen",
            profileIdentifier: "jensen"
        )
        model.wakeMappings = [replacement]

        let published = await model.publish()

        XCTAssertTrue(published)
        XCTAssertEqual(
            model.verifiedConfiguration,
            DeviceSetupConfiguration(
                deviceID: approvedSetupDevice.id,
                room: "Kitchen",
                wakeMappings: [replacement]
            )
        )
        XCTAssertNil(model.pendingConfiguration)
        XCTAssertEqual(model.publicationStatus, .verified)
        let lastConfiguration = await administrationClient.lastConfiguration()
        XCTAssertEqual(lastConfiguration?.wakeMappings.first?.profileIdentifier, "jensen")
        let persistedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(
            persistedState?.verifiedConfiguration.wakeMappings.first?.profileIdentifier,
            "jensen"
        )
        XCTAssertNil(persistedState?.pendingConfiguration)
    }

    func testRevokedIdentityCannotPublishMappingEdit() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = kitchenConfiguration(for: approvedSetupDevice)
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: verified,
                pendingConfiguration: nil,
                identityStatus: .revoked
            )
        )
        let administrationClient = FakeDeviceAdministrationClient()
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store
        )
        await model.load()
        model.wakeMappings = [
            DeviceWakeMapping(wakePhrase: "Hey Jensen", profileIdentifier: "jensen")
        ]

        let published = await model.publish()

        XCTAssertFalse(published)
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(
            model.errorMessage,
            "Device access is revoked. Explicit re-enrollment is required."
        )
        let configurationCount = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCount, 0)
    }

    func testSemanticallyMatchingMappingReceiptIgnoresLocalMappingIdentifier() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "Kitchen",
            wakeMappings: [
                DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
            ]
        )
        try await store.save(
            DeviceConfigurationState(
                verifiedConfiguration: verified,
                pendingConfiguration: nil
            )
        )
        let replacement = DeviceWakeMapping(
            wakePhrase: "Hey Jensen",
            profileIdentifier: "jensen"
        )
        let administrationClient = FakeDeviceAdministrationClient(
            configurationReceipt: DeviceSetupConfiguration(
                deviceID: approvedSetupDevice.id,
                room: "Kitchen",
                wakeMappings: [
                    DeviceWakeMapping(
                        wakePhrase: replacement.wakePhrase,
                        profileIdentifier: replacement.profileIdentifier
                    )
                ]
            )
        )
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store
        )
        await model.load()
        model.wakeMappings = [replacement]

        let published = await model.publish()

        XCTAssertTrue(published)
        XCTAssertEqual(model.verifiedConfiguration.wakeMappings, [replacement])
        XCTAssertNil(model.pendingConfiguration)
        XCTAssertEqual(model.publicationStatus, .verified)
    }

    private var approvedSetupDevice: HouseholdDevice {
        HouseholdDevice(
            id: "approved-puck",
            displayName: "Kitchen Puck",
            kind: .puck,
            trustState: .approved
        )
    }

    private func kitchenConfiguration(for device: HouseholdDevice) -> DeviceSetupConfiguration {
        DeviceSetupConfiguration(
            deviceID: device.id,
            room: "Kitchen",
            wakeMappings: [
                DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
            ]
        )
    }

    private func temporaryDraftFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesDeviceSetupTests-\(UUID().uuidString)")
            .appendingPathComponent("device-setup-drafts.json")
    }

    private func temporaryConfigurationFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesDeviceConfigurationTests-\(UUID().uuidString)")
            .appendingPathComponent("device-configurations.json")
    }

    func testDiscoveryKeepsUnconfiguredDevicesSeparateFromApprovedDevices() async {
        let approved = HouseholdDevice(
            id: "approved-display",
            displayName: "Kitchen Display",
            kind: .display,
            trustState: .approved
        )
        let discovered = HouseholdDevice(
            id: "unconfigured-puck",
            displayName: "New Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let secondDiscovered = HouseholdDevice(
            id: "unconfigured-display",
            displayName: "New Display",
            kind: .display,
            trustState: .unconfigured
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [approved],
                unconfiguredDevices: [discovered, secondDiscovered]
            )
        )
        let model = DeviceDiscoveryModel(client: client)

        await model.discover()

        XCTAssertEqual(model.approvedDevices, [approved])
        XCTAssertEqual(model.discoveredDevices, [discovered, secondDiscovered])
        XCTAssertEqual(model.discoveredDevices.first?.trustState, .unconfigured)
        XCTAssertNil(model.errorMessage)
    }

    func testDiscoveryDropsMisclassifiedAndDuplicateDevices() async {
        let approved = HouseholdDevice(
            id: "approved-display",
            displayName: "Kitchen Display",
            kind: .display,
            trustState: .approved
        )
        let duplicateCandidate = HouseholdDevice(
            id: "unconfigured-puck",
            displayName: "New Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let misclassifiedApproved = HouseholdDevice(
            id: "bad-approved",
            displayName: "Unknown Approved Device",
            kind: .puck,
            trustState: .unconfigured
        )
        let misclassifiedCandidate = HouseholdDevice(
            id: "bad-candidate",
            displayName: "Already Approved Device",
            kind: .display,
            trustState: .approved
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [approved, misclassifiedApproved],
                unconfiguredDevices: [
                    duplicateCandidate,
                    duplicateCandidate,
                    misclassifiedCandidate
                ]
            )
        )
        let model = DeviceDiscoveryModel(client: client)

        await model.discover()

        XCTAssertEqual(model.approvedDevices, [approved])
        XCTAssertEqual(model.discoveredDevices, [duplicateCandidate])
    }

    func testDiscoveryDropsDeviceWithEmptyIdentifier() async {
        let malformed = HouseholdDevice(
            id: "",
            displayName: "Unnamed Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [],
                unconfiguredDevices: [malformed]
            )
        )
        let model = DeviceDiscoveryModel(client: client)

        await model.discover()

        XCTAssertTrue(model.discoveredDevices.isEmpty)
    }

    func testConnectingThenSuccessKeepsCandidateUnconfiguredAndOutOfApprovedDevices() async {
        let approved = HouseholdDevice(
            id: "approved-display",
            displayName: "Kitchen Display",
            kind: .display,
            trustState: .approved
        )
        let discovered = HouseholdDevice(
            id: "unconfigured-puck",
            displayName: "New Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [approved],
                unconfiguredDevices: [discovered]
            ),
            holdConnection: true
        )
        let model = DeviceDiscoveryModel(client: client)
        await model.discover()

        let connectionTask = Task {
            await model.connect(to: discovered)
        }
        await client.waitUntilConnectCalled()

        XCTAssertEqual(model.connectionState(for: discovered), .connecting)
        XCTAssertEqual(model.discoveredDevices, [discovered])
        XCTAssertEqual(model.approvedDevices, [approved])

        await client.releaseConnection()
        await connectionTask.value

        XCTAssertEqual(model.connectionState(for: discovered), .connected)
        XCTAssertEqual(model.discoveredDevices, [discovered])
        XCTAssertEqual(model.approvedDevices, [approved])
        XCTAssertEqual(
            model.statusMessage,
            "New Puck responded. It remains unconfigured."
        )
        let sideEffects = await client.sideEffectCounts()
        XCTAssertEqual(sideEffects, .zero)
    }

    func testLANUnavailableLeavesCandidatesInertAndEnablesManualFallback() async {
        let client = FakeDeviceDiscoveryClient(
            discoverError: .lanUnavailable
        )
        let model = DeviceDiscoveryModel(client: client)

        await model.discover()

        XCTAssertEqual(
            model.errorMessage,
            "Device discovery is unavailable. Try manual pairing."
        )
        XCTAssertTrue(model.isManualFallbackAvailable)
        XCTAssertTrue(model.discoveredDevices.isEmpty)
        XCTAssertTrue(model.approvedDevices.isEmpty)
    }

    func testUnavailableProductionAdapterDoesNotOfferAnUnsupportedFallback() async {
        let model = DeviceDiscoveryModel(client: UnavailableDeviceDiscoveryClient())

        await model.discover()

        XCTAssertEqual(
            model.errorMessage,
            "Device discovery is not configured yet. Try again when a Device transport is available."
        )
        XCTAssertFalse(model.isManualFallbackAvailable)
    }

    func testManualPairingIdentifiesUnconfiguredCandidateWithoutApproval() async {
        let candidate = HouseholdDevice(
            id: "unconfigured-puck",
            displayName: "New Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let client = FakeDeviceDiscoveryClient(
            discoverError: .lanUnavailable,
            manualDevice: candidate
        )
        let model = DeviceDiscoveryModel(client: client)
        await model.discover()
        model.manualIdentifier = "unconfigured-puck"

        let identified = await model.submitManualPairing()

        XCTAssertTrue(identified)
        XCTAssertEqual(model.discoveredDevices, [candidate])
        XCTAssertTrue(model.approvedDevices.isEmpty)
        XCTAssertEqual(model.connectionState(for: candidate), .idle)
        XCTAssertEqual(
            model.statusMessage,
            "New Puck found. It remains unconfigured."
        )
        let manualIdentifiers = await client.manualIdentifiers()
        XCTAssertEqual(manualIdentifiers, ["unconfigured-puck"])
    }

    func testManualPairingRejectsBlankIdentifierWithoutCallingClient() async {
        let client = FakeDeviceDiscoveryClient()
        let model = DeviceDiscoveryModel(client: client)
        model.manualIdentifier = " \n\t "

        let identified = await model.submitManualPairing()

        XCTAssertFalse(identified)
        XCTAssertEqual(model.errorMessage, "Enter a valid Device identifier.")
        let manualIdentifiers = await client.manualIdentifiers()
        XCTAssertTrue(manualIdentifiers.isEmpty)
    }

    func testManualPairingRejectsADeviceDifferentFromRequestedIdentifier() async {
        let differentDevice = HouseholdDevice(
            id: "other-puck",
            displayName: "Other Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let client = FakeDeviceDiscoveryClient(manualDevice: differentDevice)
        let model = DeviceDiscoveryModel(client: client)
        model.manualIdentifier = "requested-puck"

        let identified = await model.submitManualPairing()

        XCTAssertFalse(identified)
        XCTAssertEqual(
            model.errorMessage,
            "The Device identity could not be verified. Try again."
        )
        XCTAssertTrue(model.discoveredDevices.isEmpty)
        XCTAssertTrue(model.approvedDevices.isEmpty)
    }

    func testManualPairingRejectsAnAlreadyApprovedIdentity() async {
        let approved = HouseholdDevice(
            id: "approved-display",
            displayName: "Kitchen Display",
            kind: .display,
            trustState: .approved
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [approved],
                unconfiguredDevices: []
            ),
            manualDevice: HouseholdDevice(
                id: approved.id,
                displayName: approved.displayName,
                kind: approved.kind,
                trustState: .unconfigured
            )
        )
        let model = DeviceDiscoveryModel(client: client)
        await model.discover()
        model.manualIdentifier = approved.id

        let identified = await model.submitManualPairing()

        XCTAssertFalse(identified)
        XCTAssertEqual(model.approvedDevices, [approved])
        XCTAssertTrue(model.discoveredDevices.isEmpty)
        XCTAssertEqual(
            model.errorMessage,
            "The Device identity could not be verified. Try again."
        )
    }

    func testApprovedDeviceCannotBeSelectedForUnconfiguredConnection() async {
        let approved = HouseholdDevice(
            id: "approved-display",
            displayName: "Kitchen Display",
            kind: .display,
            trustState: .approved
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [approved],
                unconfiguredDevices: []
            )
        )
        let model = DeviceDiscoveryModel(client: client)
        await model.discover()

        await model.connect(to: approved)

        XCTAssertEqual(
            model.errorMessage,
            "That Device could not be found. Try discovery again."
        )
        let connectCallCount = await client.connectCallCountValue()
        XCTAssertEqual(connectCallCount, 0)
    }

    func testConnectionFailureKeepsCandidateUnconfiguredAndOffersRecovery() async {
        let approved = HouseholdDevice(
            id: "approved-display",
            displayName: "Kitchen Display",
            kind: .display,
            trustState: .approved
        )
        let candidate = HouseholdDevice(
            id: "unconfigured-puck",
            displayName: "New Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [approved],
                unconfiguredDevices: [candidate]
            ),
            connectionError: .connectionFailed
        )
        let model = DeviceDiscoveryModel(client: client)
        await model.discover()

        await model.connect(to: candidate)

        XCTAssertEqual(
            model.connectionState(for: candidate),
            .failed(.connectionFailed)
        )
        XCTAssertEqual(
            model.errorMessage,
            "The Device could not be connected. Try again."
        )
        XCTAssertTrue(model.isManualFallbackAvailable)
        XCTAssertEqual(model.discoveredDevices, [candidate])
        XCTAssertEqual(model.approvedDevices, [approved])
    }

    func testConnectionUsesStableDeviceIDWhenCandidatePresentationChanges() async {
        let discovered = HouseholdDevice(
            id: "unconfigured-puck",
            displayName: "New Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let refreshedPresentation = HouseholdDevice(
            id: discovered.id,
            displayName: "New Puck in Hallway",
            kind: .puck,
            trustState: .unconfigured
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [],
                unconfiguredDevices: [discovered]
            )
        )
        let model = DeviceDiscoveryModel(client: client)
        await model.discover()

        await model.connect(to: refreshedPresentation)

        XCTAssertEqual(model.connectionState(for: discovered), .connected)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.discoveredDevices, [discovered])
    }

    func testMismatchedConnectionReceiptFailsClosedWithoutPromotion() async {
        let candidate = HouseholdDevice(
            id: "unconfigured-puck",
            displayName: "New Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [],
                unconfiguredDevices: [candidate]
            ),
            receiptDeviceID: "different-device"
        )
        let model = DeviceDiscoveryModel(client: client)
        await model.discover()

        await model.connect(to: candidate)

        XCTAssertEqual(
            model.connectionState(for: candidate),
            .failed(.unexpectedResponse)
        )
        XCTAssertEqual(
            model.errorMessage,
            "The Device identity could not be verified. Try again."
        )
        XCTAssertEqual(model.discoveredDevices, [candidate])
        XCTAssertTrue(model.approvedDevices.isEmpty)
        XCTAssertFalse(model.isManualFallbackAvailable)
    }

    func testDiscoveryExcludesAnApprovedIdentityReturnedAsUnconfigured() async {
        let approved = HouseholdDevice(
            id: "shared-device-id",
            displayName: "Kitchen Display",
            kind: .display,
            trustState: .approved
        )
        let misclassified = HouseholdDevice(
            id: approved.id,
            displayName: approved.displayName,
            kind: approved.kind,
            trustState: .unconfigured
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [approved],
                unconfiguredDevices: [misclassified]
            )
        )
        let model = DeviceDiscoveryModel(client: client)

        await model.discover()

        XCTAssertEqual(model.approvedDevices, [approved])
        XCTAssertTrue(model.discoveredDevices.isEmpty)
    }

    func testLatestDiscoveryWinsWhenRequestsOverlap() async {
        let olderDevice = HouseholdDevice(
            id: "older-device",
            displayName: "Older Device",
            kind: .puck,
            trustState: .unconfigured
        )
        let newerDevice = HouseholdDevice(
            id: "newer-device",
            displayName: "Newer Device",
            kind: .display,
            trustState: .unconfigured
        )
        let client = SequencedDeviceDiscoveryClient()
        let model = DeviceDiscoveryModel(client: client)

        let firstDiscovery = Task { await model.discover() }
        await client.waitUntilCallCount(1)
        let secondDiscovery = Task { await model.discover() }
        await client.waitUntilCallCount(2)

        await client.release(
            call: 2,
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [],
                unconfiguredDevices: [newerDevice]
            )
        )
        await client.release(
            call: 1,
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [],
                unconfiguredDevices: [olderDevice]
            )
        )
        await firstDiscovery.value
        await secondDiscovery.value

        XCTAssertEqual(model.discoveredDevices, [newerDevice])
        XCTAssertFalse(model.isDiscovering)
    }

    func testConnectionDoesNotStartWhileDiscoveryIsRefreshing() async {
        let candidate = HouseholdDevice(
            id: "unconfigured-puck",
            displayName: "New Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let client = RefreshingDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [],
                unconfiguredDevices: [candidate]
            )
        )
        let model = DeviceDiscoveryModel(client: client)
        await model.discover()

        let refresh = Task { await model.discover() }
        await client.waitUntilRefreshStarts()

        await model.connect(to: candidate)

        XCTAssertEqual(
            model.errorMessage,
            "Finish Device discovery before connecting."
        )
        let connectCallCount = await client.connectCallCountValue()
        XCTAssertEqual(connectCallCount, 0)

        await client.releaseRefresh()
        await refresh.value

        XCTAssertNil(model.errorMessage)
    }

    func testLateConnectionResultIsIgnoredAfterRefreshRemovesCandidate() async {
        let candidate = HouseholdDevice(
            id: "unconfigured-puck",
            displayName: "New Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let client = RefreshingConnectionDiscoveryClient(
            initialSnapshot: DeviceDiscoverySnapshot(
                approvedDevices: [],
                unconfiguredDevices: [candidate]
            )
        )
        let model = DeviceDiscoveryModel(client: client)
        await model.discover()

        let connection = Task { await model.connect(to: candidate) }
        await client.waitUntilConnectStarts()

        await model.discover()
        await client.releaseConnection()
        await connection.value

        XCTAssertTrue(model.discoveredDevices.isEmpty)
        XCTAssertNotEqual(model.connectionState(for: candidate), .connected)
    }

    func testDiscoveryCancellationDoesNotBecomeAUserFacingFailure() async {
        let model = DeviceDiscoveryModel(client: CancellationDeviceDiscoveryClient())

        await model.discover()

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isDiscovering)
        XCTAssertTrue(model.approvedDevices.isEmpty)
        XCTAssertTrue(model.discoveredDevices.isEmpty)
    }

    #if os(iOS)
    func testDeviceDiscoveryViewHostsWithDeterministicClient() {
        let candidate = HouseholdDevice(
            id: "unconfigured-puck",
            displayName: "New Puck",
            kind: .puck,
            trustState: .unconfigured
        )
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [],
                unconfiguredDevices: [candidate]
            )
        )
        let controller = UIHostingController(
            rootView: DeviceDiscoveryView(client: client)
        )

        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()

        XCTAssertNotNil(controller.view)
    }
    #endif
}

private struct DeviceDiscoverySideEffectCounts: Equatable, Sendable {
    let approvals: Int
    let credentials: Int
    let captures: Int
    let hermesTurns: Int

    static let zero = DeviceDiscoverySideEffectCounts(
        approvals: 0,
        credentials: 0,
        captures: 0,
        hermesTurns: 0
    )
}

private actor FakeDeviceDiscoveryClient: DeviceDiscoveryClient {
    let snapshot: DeviceDiscoverySnapshot
    let discoverError: DeviceDiscoveryError?
    let manualDevice: HouseholdDevice?
    let connectionError: DeviceDiscoveryError?
    let receiptDeviceID: String?
    let holdConnection: Bool
    private var connectCallCount = 0
    private var connectionContinuation: CheckedContinuation<Void, Never>?
    private let sideEffects = DeviceDiscoverySideEffectCounts.zero

    init(
        snapshot: DeviceDiscoverySnapshot = DeviceDiscoverySnapshot(
            approvedDevices: [],
            unconfiguredDevices: []
        ),
        discoverError: DeviceDiscoveryError? = nil,
        manualDevice: HouseholdDevice? = nil,
        connectionError: DeviceDiscoveryError? = nil,
        receiptDeviceID: String? = nil,
        holdConnection: Bool = false
    ) {
        self.snapshot = snapshot
        self.discoverError = discoverError
        self.manualDevice = manualDevice
        self.connectionError = connectionError
        self.receiptDeviceID = receiptDeviceID
        self.holdConnection = holdConnection
    }

    func discover() async throws -> DeviceDiscoverySnapshot {
        if let discoverError {
            throw discoverError
        }
        return snapshot
    }

    func connect(to device: HouseholdDevice) async throws -> DeviceConnectionReceipt {
        connectCallCount += 1
        if let connectionError {
            throw connectionError
        }
        if holdConnection {
            await withCheckedContinuation { continuation in
                connectionContinuation = continuation
            }
        }
        return DeviceConnectionReceipt(deviceID: receiptDeviceID ?? device.id)
    }

    func waitUntilConnectCalled() async {
        while connectCallCount == 0 {
            await Task.yield()
        }
    }

    func connectCallCountValue() -> Int {
        connectCallCount
    }

    func sideEffectCounts() -> DeviceDiscoverySideEffectCounts {
        sideEffects
    }

    func releaseConnection() {
        connectionContinuation?.resume()
        connectionContinuation = nil
    }

    func identifyManually(_ identifier: String) async throws -> HouseholdDevice {
        requestedManualIdentifiers.append(identifier)
        if let manualDevice {
            return manualDevice
        }
        throw DeviceDiscoveryError.manualPairingUnavailable
    }

    private var requestedManualIdentifiers: [String] = []

    func manualIdentifiers() -> [String] {
        requestedManualIdentifiers
    }
}

private actor FakeDeviceAdministrationClient: DeviceAdministrationClient {
    let approvalError: DeviceAdministrationError?
    let configurationError: DeviceAdministrationError?
    let verificationError: DeviceAdministrationError?
    let approvalReceiptDeviceID: String?
    let configurationReceiptDeviceID: String?
    let configurationReceipt: DeviceSetupConfiguration?
    let verificationReceiptDeviceID: String?
    let verificationStatus: DeviceIdentityStatus
    let verificationStatusByDeviceID: [String: DeviceIdentityStatus]
    let verificationConfiguration: DeviceSetupConfiguration?
    private var approvals = 0
    private var configurations: [DeviceSetupConfiguration] = []
    private var verifications = 0

    init(
        approvalError: DeviceAdministrationError? = nil,
        configurationError: DeviceAdministrationError? = nil,
        verificationError: DeviceAdministrationError? = nil,
        approvalReceiptDeviceID: String? = nil,
        configurationReceiptDeviceID: String? = nil,
        configurationReceipt: DeviceSetupConfiguration? = nil,
        verificationReceiptDeviceID: String? = nil,
        verificationStatus: DeviceIdentityStatus = .verified,
        verificationStatusByDeviceID: [String: DeviceIdentityStatus] = [:],
        verificationConfiguration: DeviceSetupConfiguration? = nil
    ) {
        self.approvalError = approvalError
        self.configurationError = configurationError
        self.verificationError = verificationError
        self.approvalReceiptDeviceID = approvalReceiptDeviceID
        self.configurationReceiptDeviceID = configurationReceiptDeviceID
        self.configurationReceipt = configurationReceipt
        self.verificationReceiptDeviceID = verificationReceiptDeviceID
        self.verificationStatus = verificationStatus
        self.verificationStatusByDeviceID = verificationStatusByDeviceID
        self.verificationConfiguration = verificationConfiguration
    }

    func approve(_ device: HouseholdDevice) async throws -> DeviceApprovalReceipt {
        approvals += 1
        if let approvalError {
            throw approvalError
        }
        return DeviceApprovalReceipt(deviceID: approvalReceiptDeviceID ?? device.id)
    }

    func configure(
        _ configuration: DeviceSetupConfiguration
    ) async throws -> DeviceConfigurationReceipt {
        if let configurationError {
            throw configurationError
        }
        configurations.append(configuration)
        return DeviceConfigurationReceipt(
            deviceID: configurationReceiptDeviceID ?? configuration.deviceID,
            configuration: configurationReceipt ?? configuration
        )
    }

    func verify(
        _ device: HouseholdDevice,
        against configuration: DeviceSetupConfiguration
    ) async throws -> DeviceVerificationReceipt {
        verifications += 1
        if let verificationError {
            throw verificationError
        }
        let status = verificationStatusByDeviceID[device.id] ?? verificationStatus
        return DeviceVerificationReceipt(
            deviceID: verificationReceiptDeviceID ?? device.id,
            status: status,
            configuration: verificationConfiguration ?? configuration
        )
    }

    func approvalCount() -> Int {
        approvals
    }

    func configurationCount() -> Int {
        configurations.count
    }

    func lastConfiguration() -> DeviceSetupConfiguration? {
        configurations.last
    }

    func verificationCount() -> Int {
        verifications
    }
}

private actor SequencedDeviceDiscoveryClient: DeviceDiscoveryClient {
    private var callCount = 0
    private var continuations: [Int: CheckedContinuation<DeviceDiscoverySnapshot, Never>] = [:]

    func discover() async throws -> DeviceDiscoverySnapshot {
        callCount += 1
        let call = callCount
        return await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func connect(to device: HouseholdDevice) async throws -> DeviceConnectionReceipt {
        DeviceConnectionReceipt(deviceID: device.id)
    }

    func identifyManually(_ identifier: String) async throws -> HouseholdDevice {
        throw DeviceDiscoveryError.manualPairingUnavailable
    }

    func waitUntilCallCount(_ expected: Int) async {
        while callCount < expected {
            await Task.yield()
        }
    }

    func release(call: Int, snapshot: DeviceDiscoverySnapshot) {
        continuations.removeValue(forKey: call)?.resume(returning: snapshot)
    }
}

private actor RefreshingDeviceDiscoveryClient: DeviceDiscoveryClient {
    let snapshot: DeviceDiscoverySnapshot
    private var discoverCallCount = 0
    private var refreshContinuation: CheckedContinuation<DeviceDiscoverySnapshot, Never>?
    private var connectCallCount = 0

    init(snapshot: DeviceDiscoverySnapshot) {
        self.snapshot = snapshot
    }

    func discover() async throws -> DeviceDiscoverySnapshot {
        discoverCallCount += 1
        guard discoverCallCount > 1 else { return snapshot }
        return await withCheckedContinuation { continuation in
            refreshContinuation = continuation
        }
    }

    func connect(to device: HouseholdDevice) async throws -> DeviceConnectionReceipt {
        connectCallCount += 1
        return DeviceConnectionReceipt(deviceID: device.id)
    }

    func identifyManually(_ identifier: String) async throws -> HouseholdDevice {
        throw DeviceDiscoveryError.manualPairingUnavailable
    }

    func waitUntilRefreshStarts() async {
        while discoverCallCount < 2 {
            await Task.yield()
        }
    }

    func releaseRefresh() {
        refreshContinuation?.resume(returning: snapshot)
        refreshContinuation = nil
    }

    func connectCallCountValue() -> Int {
        connectCallCount
    }
}

private actor RefreshingConnectionDiscoveryClient: DeviceDiscoveryClient {
    let initialSnapshot: DeviceDiscoverySnapshot
    private var discoverCallCount = 0
    private var connectionContinuation: CheckedContinuation<Void, Never>?
    private var didStartConnection = false

    init(initialSnapshot: DeviceDiscoverySnapshot) {
        self.initialSnapshot = initialSnapshot
    }

    func discover() async throws -> DeviceDiscoverySnapshot {
        discoverCallCount += 1
        guard discoverCallCount == 1 else {
            return DeviceDiscoverySnapshot(approvedDevices: [], unconfiguredDevices: [])
        }
        return initialSnapshot
    }

    func connect(to device: HouseholdDevice) async throws -> DeviceConnectionReceipt {
        didStartConnection = true
        await withCheckedContinuation { continuation in
            connectionContinuation = continuation
        }
        return DeviceConnectionReceipt(deviceID: device.id)
    }

    func identifyManually(_ identifier: String) async throws -> HouseholdDevice {
        throw DeviceDiscoveryError.manualPairingUnavailable
    }

    func waitUntilConnectStarts() async {
        while !didStartConnection {
            await Task.yield()
        }
    }

    func releaseConnection() {
        connectionContinuation?.resume()
        connectionContinuation = nil
    }
}

private struct CancellationDeviceDiscoveryClient: DeviceDiscoveryClient {
    func discover() async throws -> DeviceDiscoverySnapshot {
        throw CancellationError()
    }

    func connect(to device: HouseholdDevice) async throws -> DeviceConnectionReceipt {
        throw CancellationError()
    }

    func identifyManually(_ identifier: String) async throws -> HouseholdDevice {
        throw CancellationError()
    }
}
