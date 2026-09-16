import Foundation
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

    func testDeviceSetupConfigurationDecodesLegacyStateWithoutHomeMetadata() throws {
        let data = Data(
            #"{"deviceID":"puck-kitchen","room":"Kitchen","wakeMappings":[],"arbitrationPriority":1}"#.utf8
        )

        let configuration = try JSONDecoder().decode(
            DeviceSetupConfiguration.self,
            from: data
        )

        XCTAssertNil(configuration.displayName)
        XCTAssertNil(configuration.profileIdentifier)
        XCTAssertTrue(configuration.wakeClaimEnabled)
        XCTAssertEqual(configuration.arbitrationPriority, 1)
    }

    func testHomeConfigurationReceiptMatchesCanonicalWakePhraseFormatting() {
        let mappingID = CanonicalWakeMappingID("hey-hermes")
        let requested = DeviceSetupConfiguration(
            deviceID: "puck-kitchen",
            room: "kitchen",
            wakeMappings: [
                DeviceWakeMapping(
                    wakePhrase: " hey   hermes ",
                    profileIdentifier: " family ",
                    canonicalID: mappingID
                )
            ],
            arbitrationPriority: 1
        )
        let canonical = DeviceSetupConfiguration(
            deviceID: "puck-kitchen",
            room: "kitchen",
            wakeMappings: [
                DeviceWakeMapping(
                    wakePhrase: "Hey Hermes",
                    profileIdentifier: "family",
                    canonicalID: mappingID
                )
            ],
            arbitrationPriority: 1
        )

        let receipt = DeviceConfigurationReceipt(
            deviceID: canonical.deviceID,
            configuration: canonical
        )

        XCTAssertTrue(receipt.matches(requested))
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
                DeviceWakeMapping(wakePhrase: "Hey Relay", profileIdentifier: "primary")
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

    func testHomeIneligibleDeviceIsNotRestoredByLaterDiscoveryVerification() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = kitchenConfiguration(for: approvedSetupDevice)
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: verified,
                pendingConfiguration: nil,
                homeConfigurationRevision: 7,
                homeEligibility: .ineligible,
                identityStatus: .verified
            )
        )
        let discoveryClient = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [approvedSetupDevice],
                unconfiguredDevices: []
            )
        )
        let administrationClient = FakeDeviceAdministrationClient()
        let model = DeviceDiscoveryModel(
            client: discoveryClient,
            administrationClient: administrationClient,
            configurationStore: store
        )

        await model.discover()

        XCTAssertEqual(model.setupStatus(for: approvedSetupDevice), .unavailable)
        XCTAssertFalse(model.isActive(approvedSetupDevice))
        let verificationCount = await administrationClient.verificationCount()
        XCTAssertEqual(verificationCount, 0)
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

    func testReachablePendingRevocationDoesNotRestoreVerification() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: kitchenConfiguration(for: approvedSetupDevice),
                pendingConfiguration: nil,
                identityStatus: .revocationPending
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

        XCTAssertEqual(model.setupStatus(for: approvedSetupDevice), .revocationPending)
        XCTAssertFalse(model.isActive(approvedSetupDevice))
        let verificationCount = await administrationClient.verificationCount()
        XCTAssertEqual(verificationCount, 0)
    }

    func testExplicitReenrollmentKeepsDeviceRevokedUntilOrderedSetupCompletes() async throws {
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

        let reEnrolled = await model.reEnroll(approvedSetupDevice)
        let reEnrollmentCount = await administrationClient.reEnrollmentCount()

        XCTAssertTrue(reEnrolled)
        XCTAssertEqual(model.setupStatus(for: approvedSetupDevice), .revoked)
        XCTAssertFalse(model.isActive(approvedSetupDevice))
        XCTAssertEqual(reEnrollmentCount, 1)
        let persistedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(persistedState?.identityStatus, .revoked)
    }

    func testReenrollmentBecomesVerifiedOnlyAfterOrderedSetupPublishes() async throws {
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
        let discoveryModel = DeviceDiscoveryModel(
            client: client,
            administrationClient: administrationClient,
            configurationStore: store
        )

        await discoveryModel.discover()
        let reEnrolled = await discoveryModel.reEnroll(approvedSetupDevice)
        XCTAssertTrue(reEnrolled)
        let stateBeforeSetup = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(stateBeforeSetup?.identityStatus, .revoked)

        let setup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store
        )
        setup.room = "Kitchen"
        XCTAssertTrue(setup.continueFromRoom())
        setup.wakeMappings = [
            DeviceWakeMapping(wakePhrase: "Hey Missy", profileIdentifier: "missy")
        ]
        XCTAssertTrue(setup.continueFromMappings())

        let completed = await setup.confirmReady()

        XCTAssertTrue(completed)
        let stateAfterSetup = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(stateAfterSetup?.identityStatus, .verified)
    }

    func testFailedReenrollmentLeavesDeviceRevokedAndInactive() async throws {
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
        let administrationClient = FakeDeviceAdministrationClient(
            reEnrollmentError: .reEnrollmentFailed
        )
        let model = DeviceDiscoveryModel(
            client: client,
            administrationClient: administrationClient,
            configurationStore: store
        )

        await model.discover()

        let reEnrolled = await model.reEnroll(approvedSetupDevice)

        XCTAssertFalse(reEnrolled)
        XCTAssertEqual(model.setupStatus(for: approvedSetupDevice), .revoked)
        XCTAssertFalse(model.isActive(approvedSetupDevice))
        XCTAssertEqual(
            model.errorMessage,
            "The Device could not be re-enrolled. It remains unavailable. Try again."
        )
        let reEnrollmentCount = await administrationClient.reEnrollmentCount()
        XCTAssertEqual(reEnrollmentCount, 1)
    }

    func testMismatchedReenrollmentReceiptLeavesDeviceRevoked() async throws {
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
        let administrationClient = FakeDeviceAdministrationClient(
            reEnrollmentReceiptDeviceID: "different-device"
        )
        let model = DeviceDiscoveryModel(
            client: client,
            administrationClient: administrationClient,
            configurationStore: store
        )

        await model.discover()

        let reEnrolled = await model.reEnroll(approvedSetupDevice)

        XCTAssertFalse(reEnrolled)
        XCTAssertEqual(model.setupStatus(for: approvedSetupDevice), .revoked)
        XCTAssertFalse(model.isActive(approvedSetupDevice))
        XCTAssertEqual(
            model.errorMessage,
            "The Device could not be re-enrolled. It remains unavailable. Try again."
        )
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
                    DeviceWakeMapping(wakePhrase: "Hey Relay", profileIdentifier: "primary")
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
                DeviceWakeMapping(wakePhrase: "Hey Relay", profileIdentifier: "primary")
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
            DeviceWakeMapping(wakePhrase: "Hey Relay", profileIdentifier: "primary")
        ]

        let preserved = await model.preservePending()

        XCTAssertTrue(preserved)
        XCTAssertEqual(model.publicationStatus, .pending)
        let configurationCount = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCount, 0)
        let persistedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(
            persistedState?.pendingConfiguration?.wakeMappings.first?.profileIdentifier,
            "primary"
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
                DeviceWakeMapping(wakePhrase: "Hey Relay", profileIdentifier: "primary")
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
                DeviceWakeMapping(wakePhrase: "Hey Relay", profileIdentifier: "primary")
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
            DeviceWakeMapping(wakePhrase: " hey missy ", profileIdentifier: "primary")
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
            wakePhrase: "Hey Relay",
            profileIdentifier: "primary"
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
        XCTAssertEqual(lastConfiguration?.wakeMappings.first?.profileIdentifier, "primary")
        let persistedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(
            persistedState?.verifiedConfiguration.wakeMappings.first?.profileIdentifier,
            "primary"
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
            DeviceWakeMapping(wakePhrase: "Hey Relay", profileIdentifier: "primary")
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

    func testDisconnectMarksLocalConfigurationRevokedAfterConfirmedReceipt() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: kitchenConfiguration(for: approvedSetupDevice),
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

        let disconnected = await model.revoke()

        XCTAssertTrue(disconnected)
        XCTAssertEqual(model.identityStatus, .revoked)
        XCTAssertFalse(model.isActive)
        let persistedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(persistedState?.identityStatus, .revoked)
    }

    func testConfirmedDisconnectClearsPendingMappingEdit() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: kitchenConfiguration(for: approvedSetupDevice),
                pendingConfiguration: DeviceSetupConfiguration(
                    deviceID: approvedSetupDevice.id,
                    room: "Study",
                    wakeMappings: [
                        DeviceWakeMapping(
                            wakePhrase: "Hey Relay",
                            profileIdentifier: "primary"
                        )
                    ]
                )
            )
        )
        let administrationClient = FakeDeviceAdministrationClient()
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store
        )
        await model.load()

        let disconnected = await model.revoke()

        XCTAssertTrue(disconnected)
        XCTAssertEqual(model.identityStatus, .revoked)
        XCTAssertNil(model.pendingConfiguration)
        let persistedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(persistedState?.identityStatus, .revoked)
        XCTAssertNil(persistedState?.pendingConfiguration)
    }

    func testRevokedConfigurationDoesNotPreserveMappingEditOnDismiss() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let verified = kitchenConfiguration(for: approvedSetupDevice)
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
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
            DeviceWakeMapping(wakePhrase: "Hey Relay", profileIdentifier: "primary")
        ]

        let disconnected = await model.revoke()
        XCTAssertTrue(disconnected)
        let preserved = await model.preservePending()

        XCTAssertTrue(preserved)
        let persistedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(persistedState?.identityStatus, .revoked)
        XCTAssertNil(persistedState?.pendingConfiguration)
    }

    func testFailedDisconnectPersistsPendingRevocationAndLeavesDeviceInactive() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: kitchenConfiguration(for: approvedSetupDevice),
                pendingConfiguration: nil
            )
        )
        let administrationClient = FakeDeviceAdministrationClient(
            revocationError: .revocationFailed
        )
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store
        )
        await model.load()

        let disconnected = await model.revoke()

        XCTAssertFalse(disconnected)
        XCTAssertEqual(model.identityStatus, .revocationPending)
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(
            model.errorMessage,
            "Device access could not be confirmed. It remains unavailable until you retry."
        )
        let persistedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(persistedState?.identityStatus, .revocationPending)
    }

    func testMismatchedDisconnectReceiptPersistsPendingRevocation() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: kitchenConfiguration(for: approvedSetupDevice),
                pendingConfiguration: nil
            )
        )
        let administrationClient = FakeDeviceAdministrationClient(
            revocationReceiptDeviceID: "different-device"
        )
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store
        )
        await model.load()

        let disconnected = await model.revoke()

        XCTAssertFalse(disconnected)
        XCTAssertEqual(model.identityStatus, .revocationPending)
        XCTAssertFalse(model.isActive)
        let persistedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(persistedState?.identityStatus, .revocationPending)
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
            wakePhrase: "Hey Relay",
            profileIdentifier: "primary"
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

    private func homeAdminRoute(
        host: String = "home.example",
        identityID: String = "home",
        householdBinding: String = "household-a"
    ) -> HomeApprovedRoute {
        HomeApprovedRoute(
            endpoint: URL(string: "wss://\(host)/api/v1/bridge/ws")!,
            identity: HomeRouteIdentity(routeClass: .home, id: identityID),
            householdBinding: householdBinding
        )
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
        XCTAssertEqual(
            model.discoveryErrorMessage,
            "Device discovery is unavailable. Try manual pairing."
        )
    }

    func testSuccessfulDiscoveryClearsTheDiscoveryRecoveryState() async {
        let client = FakeDeviceDiscoveryClient(
            snapshot: DeviceDiscoverySnapshot(
                approvedDevices: [],
                unconfiguredDevices: []
            )
        )
        let model = DeviceDiscoveryModel(client: client)

        await model.discover()

        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.discoveryErrorMessage)
        XCTAssertFalse(model.isDiscovering)
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

    func testHomeServiceFetchesConfigurationUsingVersionedEndpointAndAdminBearer() async throws {
        let responseBody = Data(
            #"""
            {
              "schema": 1,
              "snapshot": {
                "revision": 12,
                "rooms": [{"id": "kitchen", "name": "Kitchen"}],
                "wake_mappings": [{"id": "hey-hermes", "name": "Hey Hermes"}],
                "devices": [{
                  "id": "puck-kitchen",
                  "name": "Kitchen Puck",
                  "room_id": "kitchen",
                  "profile_id": "family",
                  "priority": 1,
                  "capabilities": {"wake_claim": true}
                }]
              }
            }
            """#.utf8
        )
        let transport = RecordingHomeHTTPTransport(body: responseBody)
        let client = URLSessionHomeServiceClient(
            baseURL: URL(string: "http://home.test")!,
            adminCredential: "home-admin-secret",
            transport: transport
        )

        let snapshot = try await client.fetchConfiguration()

        XCTAssertEqual(snapshot.revision, 12)
        XCTAssertEqual(snapshot.rooms, [HomeRoom(id: "kitchen", name: "Kitchen")])
        XCTAssertEqual(snapshot.wakeMappings.map(\.id.rawValue), ["hey-hermes"])
        XCTAssertEqual(snapshot.devices.map(\.deviceID), ["puck-kitchen"])
        XCTAssertEqual(snapshot.devices.first?.room, "kitchen")
        XCTAssertEqual(snapshot.devices.first?.displayName, "Kitchen Puck")
        XCTAssertEqual(
            snapshot.devices.first?.wakeMappings.first?.profileIdentifier,
            "family"
        )

        let request = await transport.lastRequest()
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(
            request?.url?.absoluteString,
            "http://home.test/api/v1/configuration"
        )
        XCTAssertEqual(
            request?.value(forHTTPHeaderField: "Authorization"),
            "Bearer home-admin-secret"
        )
        XCTAssertEqual(
            request?.value(forHTTPHeaderField: "Accept"),
            "application/json"
        )
    }

    func testHomeServicePublishesCompleteConfigurationWithExpectedRevision() async throws {
        let responseBody = Data(
            #"""
            {
              "schema": 1,
              "snapshot": {
                "revision": 13,
                "rooms": [{"id": "kitchen", "name": "Kitchen"}],
                "wake_mappings": [{"id": "hey-hermes", "name": "Hey Hermes"}],
                "devices": [{
                  "id": "puck-kitchen",
                  "name": "Kitchen Puck",
                  "room_id": "kitchen",
                  "profile_id": " family ",
                  "priority": 1,
                  "capabilities": {"wake_claim": true}
                }]
              }
            }
            """#.utf8
        )
        let mappingID = CanonicalWakeMappingID("hey-hermes")
        let configuration = HomeConfigurationSnapshot(
            revision: 12,
            wakeMappings: [
                CanonicalWakeMapping(id: mappingID, wakePhrase: "Hey Hermes")
            ],
            devices: [
                DeviceSetupConfiguration(
                    deviceID: "puck-kitchen",
                    room: "kitchen",
                    wakeMappings: [
                        DeviceWakeMapping(
                            wakePhrase: "Hey Hermes",
                            profileIdentifier: " family ",
                            canonicalID: mappingID
                        )
                    ],
                    arbitrationPriority: 1,
                    displayName: "Kitchen Puck",
                    profileIdentifier: " family "
                )
            ],
            rooms: [HomeRoom(id: "kitchen", name: "Kitchen")]
        )
        let transport = RecordingHomeHTTPTransport(body: responseBody)
        let client = URLSessionHomeServiceClient(
            baseURL: URL(string: "wss://home.test/api/v1/bridge/ws")!,
            adminCredential: "home-admin-secret",
            transport: transport
        )

        let published = try await client.publish(configuration, expectedRevision: 12)

        XCTAssertEqual(published.revision, 13)
        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://home.test/api/v1/configuration"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )

        let requestBody = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["expected_revision"] as? Int, 12)
        let snapshot = try XCTUnwrap(object["snapshot"] as? [String: Any])
        XCTAssertNil(snapshot["revision"])
        XCTAssertEqual(snapshot["rooms"] as? [[String: String]], [[
            "id": "kitchen",
            "name": "Kitchen"
        ]])
        XCTAssertEqual(snapshot["wake_mappings"] as? [[String: String]], [[
            "id": "hey-hermes",
            "name": "Hey Hermes"
        ]])
        let devices = try XCTUnwrap(snapshot["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.first?["id"] as? String, "puck-kitchen")
        XCTAssertEqual(devices.first?["name"] as? String, "Kitchen Puck")
        XCTAssertEqual(devices.first?["room_id"] as? String, "kitchen")
        XCTAssertEqual(devices.first?["profile_id"] as? String, " family ")
        XCTAssertEqual(devices.first?["priority"] as? Int, 1)
        XCTAssertEqual(
            devices.first?["capabilities"] as? [String: Bool],
            ["wake_claim": true]
        )
        XCTAssertFalse(
            String(decoding: requestBody, as: UTF8.self).contains("home-admin-secret")
        )
    }

    func testHomeServiceMapsStaleRevisionToTypedConflict() async {
        let transport = RecordingHomeHTTPTransport(
            body: Data(
                #"{"schema":1,"error":{"code":"revision_conflict","current_revision":13}}"#.utf8
            ),
            statusCode: 409
        )
        let client = URLSessionHomeServiceClient(
            baseURL: URL(string: "http://home.test")!,
            adminCredential: "home-admin-secret",
            transport: transport
        )

        do {
            _ = try await client.fetchConfiguration()
            XCTFail("A stale Home revision must not be treated as a successful fetch")
        } catch let error as HomeServiceError {
            XCTAssertEqual(error, .revisionConflict)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHomePublishRejectsSnapshotRevisionThatDoesNotMatchPrecondition() async {
        let transport = RecordingHomeHTTPTransport(body: Data())
        let client = URLSessionHomeServiceClient(
            baseURL: URL(string: "http://home.test")!,
            adminCredential: "home-admin-secret",
            transport: transport
        )
        let snapshot = HomeConfigurationSnapshot(
            revision: 12,
            wakeMappings: [],
            devices: [],
            rooms: []
        )

        do {
            _ = try await client.publish(snapshot, expectedRevision: 13)
            XCTFail("A stale snapshot must not be sent with a newer revision precondition")
        } catch let error as HomeServiceError {
            XCTAssertEqual(error, .revisionConflict)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testInvalidHomePublishResponseExplainsThatOutcomeIsUnknown() {
        let message = HomeServiceError.invalidResponse.userMessage

        XCTAssertTrue(message.localizedCaseInsensitiveContains("result may be unknown"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("reload"))
    }

    func testHomeURLSessionRedirectDelegateRefusesRedirects() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let originalURL = URL(string: "https://home.example/configuration")!
        let task = session.dataTask(with: originalURL)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: originalURL,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://other.example/configuration"]
            )
        )
        let proposedRequest = URLRequest(
            url: URL(string: "https://other.example/configuration")!
        )
        let result = RedirectRequestResult()

        HomeRedirectRefusingDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: proposedRequest,
            completionHandler: { result.record($0) }
        )

        XCTAssertTrue(result.wasCalled)
        XCTAssertNil(result.request)
        task.cancel()
    }

    func testHomeServicePreservesDeviceProfileAndCapabilityWhenNoWakeMappingsExist() async throws {
        let responseBody = Data(
            #"""
            {
              "schema": 1,
              "snapshot": {
                "revision": 4,
                "rooms": [{"id": "study", "name": "Study"}],
                "wake_mappings": [],
                "devices": [{
                  "id": "display-study",
                  "name": "Study Display",
                  "room_id": "study",
                  "profile_id": "quiet",
                  "priority": 2,
                  "capabilities": {"wake_claim": false}
                }]
              }
            }
            """#.utf8
        )
        let client = URLSessionHomeServiceClient(
            baseURL: URL(string: "http://home.test")!,
            adminCredential: "home-admin-secret",
            transport: RecordingHomeHTTPTransport(body: responseBody)
        )

        let snapshot = try await client.fetchConfiguration()
        let device = try XCTUnwrap(snapshot.devices.first)

        XCTAssertEqual(device.profileIdentifier, "quiet")
        XCTAssertFalse(device.wakeClaimEnabled)
        XCTAssertTrue(device.wakeMappings.isEmpty)
    }

    func testHomeServiceRejectsUnknownWireFieldsAsInvalidResponse() async {
        let transport = RecordingHomeHTTPTransport(
            body: Data(
                #"{"schema":1,"snapshot":{"revision":1,"rooms":[],"wake_mappings":[],"devices":[],"unexpected":true}}"#.utf8
            )
        )
        let client = URLSessionHomeServiceClient(
            baseURL: URL(string: "http://home.test")!,
            adminCredential: "home-admin-secret",
            transport: transport
        )

        do {
            _ = try await client.fetchConfiguration()
            XCTFail("Unknown Home fields must not be silently ignored")
        } catch let error as HomeServiceError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHomeServiceRejectsDeviceSnapshotWithoutRooms() async {
        let transport = RecordingHomeHTTPTransport(
            body: Data(
                #"{"schema":1,"snapshot":{"revision":1,"rooms":[],"wake_mappings":[{"id":"wake","name":"Hey Hermes"}],"devices":[{"id":"device","name":"Device","room_id":"kitchen","profile_id":"family","priority":1,"capabilities":{"wake_claim":true}}]}}"#.utf8
            )
        )
        let client = URLSessionHomeServiceClient(
            baseURL: URL(string: "http://home.test")!,
            adminCredential: "home-admin-secret",
            transport: transport
        )

        do {
            _ = try await client.fetchConfiguration()
            XCTFail("A Home Device cannot reference a Room omitted from the complete snapshot")
        } catch let error as HomeServiceError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHomeBackedConfigurationPublishUsesHomeRevisionInsteadOfDeviceAdmin() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let mappingID = CanonicalWakeMappingID("hey-hermes")
        let canonicalMapping = CanonicalWakeMapping(
            id: mappingID,
            wakePhrase: "Hey Hermes"
        )
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "kitchen",
            wakeMappings: [
                DeviceWakeMapping(
                    wakePhrase: "Hey Hermes",
                    profileIdentifier: "family",
                    canonicalID: mappingID
                )
            ],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: "family"
        )
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: verified,
                pendingConfiguration: nil
            )
        )
        let currentHomeSnapshot = HomeConfigurationSnapshot(
            revision: 7,
            wakeMappings: [canonicalMapping],
            devices: [verified],
            rooms: [HomeRoom(id: "kitchen", name: "Kitchen"), HomeRoom(id: "study", name: "Study")]
        )
        let publishedConfiguration = DeviceSetupConfiguration(
            deviceID: verified.deviceID,
            room: "study",
            wakeMappings: verified.wakeMappings,
            arbitrationPriority: 1,
            displayName: verified.displayName,
            profileIdentifier: verified.profileIdentifier,
            wakeClaimEnabled: verified.wakeClaimEnabled
        )
        let publishedHomeSnapshot = HomeConfigurationSnapshot(
            revision: 8,
            wakeMappings: [canonicalMapping],
            devices: [publishedConfiguration],
            rooms: currentHomeSnapshot.rooms
        )
        let homeClient = RecordingHomeServiceClient(
            fetchedSnapshot: currentHomeSnapshot,
            publishedSnapshot: publishedHomeSnapshot
        )
        let administrationClient = FakeDeviceAdministrationClient()
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store,
            homeServiceClient: homeClient
        )
        await model.load()
        model.room = "study"

        let published = await model.publish()

        XCTAssertTrue(published)
        XCTAssertEqual(model.homeConfigurationRevision, 8)
        XCTAssertEqual(model.verifiedConfiguration.room, "study")
        let expectedRevisions = await homeClient.publishExpectedRevisions()
        XCTAssertEqual(expectedRevisions, [7])
        let candidates = await homeClient.publishedCandidates()
        XCTAssertEqual(candidates.first?.rooms, currentHomeSnapshot.rooms)
        XCTAssertEqual(candidates.first?.wakeMappings, currentHomeSnapshot.wakeMappings)
        XCTAssertEqual(candidates.first?.devices.first?.room, "study")
        XCTAssertEqual(candidates.first?.devices.first?.displayName, approvedSetupDevice.displayName)
        XCTAssertEqual(candidates.first?.devices.first?.profileIdentifier, "family")
        XCTAssertEqual(candidates.first?.devices.first?.wakeClaimEnabled, true)
        let configurationCount = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCount, 0)
    }

    func testHomeBackedMismatchedReceiptKeepsVerifiedBasisAndPendingEdit() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let mappingID = CanonicalWakeMappingID("hey-hermes")
        let canonicalMapping = CanonicalWakeMapping(
            id: mappingID,
            wakePhrase: "Hey Hermes"
        )
        let mapping = DeviceWakeMapping(
            wakePhrase: "Hey Hermes",
            profileIdentifier: "family",
            canonicalID: mappingID
        )
        let original = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "kitchen",
            wakeMappings: [mapping],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: "family"
        )
        let currentSnapshot = HomeConfigurationSnapshot(
            revision: 7,
            wakeMappings: [canonicalMapping],
            devices: [original],
            rooms: [
                HomeRoom(id: "kitchen", name: "Kitchen"),
                HomeRoom(id: "study", name: "Study")
            ]
        )
        let mismatchedReceipt = HomeConfigurationSnapshot(
            revision: 8,
            wakeMappings: [canonicalMapping],
            devices: [
                DeviceSetupConfiguration(
                    deviceID: approvedSetupDevice.id,
                    room: "study",
                    wakeMappings: [mapping],
                    arbitrationPriority: 1,
                    displayName: "Unexpected Rename",
                    profileIdentifier: "family"
                )
            ],
            rooms: currentSnapshot.rooms
        )
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: original,
                pendingConfiguration: nil,
                homeConfigurationRevision: 7
            )
        )
        let homeClient = RecordingHomeServiceClient(
            fetchedSnapshot: currentSnapshot,
            publishedSnapshot: mismatchedReceipt
        )
        let administrationClient = FakeDeviceAdministrationClient()
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store,
            homeServiceClient: homeClient
        )
        await model.load()
        model.room = "study"

        let published = await model.publish()

        XCTAssertFalse(published)
        XCTAssertEqual(model.verifiedConfiguration, original)
        XCTAssertEqual(model.pendingConfiguration?.room, "study")
        XCTAssertEqual(model.publicationStatus, .pending)
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.errorMessage, HomeServiceError.invalidResponse.userMessage)
        let configurationCount = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCount, 0)
    }

    func testHomeReloadReconcilesHomeProjectionAndPreservesPendingEdit() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let mappingID = CanonicalWakeMappingID("hey-hermes")
        let canonicalMapping = CanonicalWakeMapping(
            id: mappingID,
            wakePhrase: "Hey Hermes"
        )
        let mapping = DeviceWakeMapping(
            wakePhrase: "Hey Hermes",
            profileIdentifier: "family",
            canonicalID: mappingID
        )
        let original = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "kitchen",
            wakeMappings: [mapping],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: "family"
        )
        let changedByHome = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "den",
            wakeMappings: [mapping],
            arbitrationPriority: 1,
            displayName: "Den Puck",
            profileIdentifier: "family"
        )
        let rooms = [
            HomeRoom(id: "kitchen", name: "Kitchen"),
            HomeRoom(id: "study", name: "Study"),
            HomeRoom(id: "den", name: "Den")
        ]
        let originalSnapshot = HomeConfigurationSnapshot(
            revision: 7,
            wakeMappings: [canonicalMapping],
            devices: [original],
            rooms: rooms
        )
        let changedSnapshot = HomeConfigurationSnapshot(
            revision: 8,
            wakeMappings: [canonicalMapping],
            devices: [changedByHome],
            rooms: rooms
        )
        let omittedSnapshot = HomeConfigurationSnapshot(
            revision: 9,
            wakeMappings: [canonicalMapping],
            devices: [],
            rooms: rooms
        )
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: original,
                pendingConfiguration: nil,
                homeConfigurationRevision: 7
            )
        )
        let homeClient = SequencedHomeServiceClient(
            snapshots: [originalSnapshot, changedSnapshot, omittedSnapshot]
        )
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient(),
            configurationStore: store,
            homeServiceClient: homeClient
        )

        await model.load()
        XCTAssertTrue(model.isActive)
        model.room = "study"
        let pendingSaved = await model.preservePending()
        XCTAssertTrue(pendingSaved)

        let changedReloaded = await model.reloadHomeConfiguration()

        XCTAssertTrue(changedReloaded)
        XCTAssertEqual(model.verifiedConfiguration, changedByHome)
        XCTAssertEqual(model.pendingConfiguration?.room, "study")
        XCTAssertEqual(model.room, "study")
        XCTAssertEqual(model.homeConfigurationRevision, 8)
        XCTAssertEqual(model.identityStatus, .verificationRequired)
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.publicationStatus, .pending)

        let omittedReloaded = await model.reloadHomeConfiguration()

        XCTAssertTrue(omittedReloaded)
        XCTAssertEqual(model.verifiedConfiguration, changedByHome)
        XCTAssertEqual(model.pendingConfiguration?.room, "study")
        XCTAssertEqual(model.identityStatus, .verificationRequired)
        XCTAssertEqual(model.homeEligibility, .ineligible)
        XCTAssertFalse(model.isActive)
        let storedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(storedState?.verifiedConfiguration, changedByHome)
        XCTAssertEqual(storedState?.pendingConfiguration?.room, "study")
        XCTAssertEqual(storedState?.identityStatus, .verificationRequired)
        XCTAssertEqual(storedState?.homeEligibility, .ineligible)
    }

    func testHomeSetupRequiresExistingDeviceAndEnabledWakeClaim() async throws {
        let mappingID = CanonicalWakeMappingID("hey-hermes")
        let canonicalMapping = CanonicalWakeMapping(
            id: mappingID,
            wakePhrase: "Hey Hermes"
        )
        let mapping = DeviceWakeMapping(
            wakePhrase: "Hey Hermes",
            profileIdentifier: "family",
            canonicalID: mappingID
        )
        let room = HomeRoom(id: "kitchen", name: "Kitchen")
        let missingSnapshot = HomeConfigurationSnapshot(
            revision: 2,
            wakeMappings: [canonicalMapping],
            devices: [],
            rooms: [room]
        )
        let missingClient = RecordingHomeServiceClient(
            fetchedSnapshot: missingSnapshot,
            publishedSnapshot: missingSnapshot
        )
        let missingSetup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient(),
            homeServiceClient: missingClient
        )
        await missingSetup.loadDraft()
        missingSetup.room = room.name
        XCTAssertTrue(missingSetup.continueFromRoom())
        missingSetup.wakeMappings = [mapping]
        XCTAssertTrue(missingSetup.continueFromMappings())

        let missingReady = await missingSetup.confirmReady()

        XCTAssertFalse(missingReady)
        XCTAssertFalse(missingSetup.isActive)
        XCTAssertEqual(missingSetup.errorMessage, HomeServiceError.notFound.userMessage)
        let missingPublishRevisions = await missingClient.publishExpectedRevisions()
        XCTAssertTrue(missingPublishRevisions.isEmpty)

        let disabledDevice = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: room.id,
            wakeMappings: [mapping],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: "family",
            wakeClaimEnabled: false
        )
        let disabledSnapshot = HomeConfigurationSnapshot(
            revision: 3,
            wakeMappings: [canonicalMapping],
            devices: [disabledDevice],
            rooms: [room]
        )
        let disabledClient = RecordingHomeServiceClient(
            fetchedSnapshot: disabledSnapshot,
            publishedSnapshot: disabledSnapshot
        )
        let disabledSetup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient(),
            homeServiceClient: disabledClient
        )
        await disabledSetup.loadDraft()
        disabledSetup.room = room.name
        XCTAssertTrue(disabledSetup.continueFromRoom())
        disabledSetup.wakeMappings = [mapping]
        XCTAssertFalse(disabledSetup.continueFromMappings())
        XCTAssertTrue(disabledSetup.errorMessage?.contains("disabled wake claims") == true)

        let disabledReady = await disabledSetup.confirmReady()

        XCTAssertFalse(disabledReady)
        XCTAssertFalse(disabledSetup.isActive)
        let disabledPublishRevisions = await disabledClient.publishExpectedRevisions()
        XCTAssertTrue(disabledPublishRevisions.isEmpty)
    }

    func testHomeBackedStalePublishKeepsVerifiedConfigurationAndPendingEdit() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let mappingID = CanonicalWakeMappingID("hey-hermes")
        let mapping = DeviceWakeMapping(
            wakePhrase: "Hey Hermes",
            profileIdentifier: "family",
            canonicalID: mappingID
        )
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "kitchen",
            wakeMappings: [mapping],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: "family"
        )
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: verified,
                pendingConfiguration: nil,
                homeConfigurationRevision: 7
            )
        )
        let homeSnapshot = HomeConfigurationSnapshot(
            revision: 7,
            wakeMappings: [CanonicalWakeMapping(id: mappingID, wakePhrase: "Hey Hermes")],
            devices: [verified],
            rooms: [HomeRoom(id: "kitchen", name: "Kitchen"), HomeRoom(id: "study", name: "Study")]
        )
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient(),
            configurationStore: store,
            homeServiceClient: ConflictingHomeServiceClient(snapshot: homeSnapshot)
        )
        await model.load()
        model.room = "study"

        let published = await model.publish()

        XCTAssertFalse(published)
        XCTAssertEqual(model.verifiedConfiguration.room, "kitchen")
        XCTAssertEqual(model.pendingConfiguration?.room, "study")
        XCTAssertEqual(model.publicationStatus, .pending)
        XCTAssertNil(model.homeConfigurationRevision)
        XCTAssertEqual(model.errorMessage, HomeServiceError.revisionConflict.userMessage)
    }

    func testHomeTransportFailureKeepsVerifiedBasisAndPersistsPendingEdit() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let mappingID = CanonicalWakeMappingID("hey-hermes")
        let mapping = DeviceWakeMapping(
            wakePhrase: "Hey Hermes",
            profileIdentifier: "family",
            canonicalID: mappingID
        )
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "kitchen",
            wakeMappings: [mapping],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: "family"
        )
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: verified,
                pendingConfiguration: nil,
                homeConfigurationRevision: 7,
                homeEligibility: .eligible,
                identityStatus: .verified
            )
        )
        let snapshot = HomeConfigurationSnapshot(
            revision: 7,
            wakeMappings: [CanonicalWakeMapping(id: mappingID, wakePhrase: "Hey Hermes")],
            devices: [verified],
            rooms: [
                HomeRoom(id: "kitchen", name: "Kitchen"),
                HomeRoom(id: "study", name: "Study")
            ]
        )
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient(),
            configurationStore: store,
            homeServiceClient: FailingPublishHomeServiceClient(
                snapshot: snapshot,
                publishError: .transportUnavailable
            )
        )
        await model.load()
        XCTAssertTrue(model.isActive)
        model.room = "study"

        let published = await model.publish()

        XCTAssertFalse(published)
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.verifiedConfiguration.room, "kitchen")
        XCTAssertEqual(model.pendingConfiguration?.room, "study")
        let persisted = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(persisted?.verifiedConfiguration.room, "kitchen")
        XCTAssertEqual(persisted?.pendingConfiguration?.room, "study")
        XCTAssertEqual(persisted?.homeEligibility, .eligible)
    }

    func testHomeReloadRebasesPendingRoomAndMappingProjectionToLatestCatalog() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let oldMappingID = CanonicalWakeMappingID("hey-hermes")
        let newMappingID = CanonicalWakeMappingID("hello-hermes")
        let oldMapping = DeviceWakeMapping(
            wakePhrase: "Hey Hermes",
            profileIdentifier: "family",
            canonicalID: oldMappingID
        )
        let newMapping = DeviceWakeMapping(
            wakePhrase: "Hello Hermes",
            profileIdentifier: "family",
            canonicalID: newMappingID
        )
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "kitchen",
            wakeMappings: [oldMapping],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: "family"
        )
        let pending = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "study",
            wakeMappings: [oldMapping],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: "family"
        )
        try await store.save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: verified,
                pendingConfiguration: pending,
                homeConfigurationRevision: 7,
                homeEligibility: .eligible,
                identityStatus: .verified
            )
        )
        let latestDevice = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "kitchen",
            wakeMappings: [newMapping],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: "family"
        )
        let latestSnapshot = HomeConfigurationSnapshot(
            revision: 8,
            wakeMappings: [CanonicalWakeMapping(id: newMappingID, wakePhrase: "Hello Hermes")],
            devices: [latestDevice],
            rooms: [HomeRoom(id: "kitchen", name: "Kitchen")]
        )
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient(),
            configurationStore: store,
            homeServiceClient: RecordingHomeServiceClient(
                fetchedSnapshot: latestSnapshot,
                publishedSnapshot: latestSnapshot
            )
        )

        await model.load()

        XCTAssertEqual(model.pendingConfiguration?.room, "kitchen")
        XCTAssertEqual(model.pendingConfiguration?.wakeMappings, [newMapping])
        XCTAssertEqual(model.room, "kitchen")
        XCTAssertEqual(model.wakeMappings, [newMapping])
        XCTAssertEqual(model.publicationStatus, .pending)
        XCTAssertFalse(model.isActive)
        let persisted = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(persisted?.pendingConfiguration?.wakeMappings, [newMapping])
        XCTAssertEqual(persisted?.homeConfigurationRevision, 8)
    }

    func testHomeEligibilityPersistenceFailureReturnsInactiveWithAnError() async throws {
        let mappingID = CanonicalWakeMappingID("hey-hermes")
        let mapping = DeviceWakeMapping(
            wakePhrase: "Hey Hermes",
            profileIdentifier: "family",
            canonicalID: mappingID
        )
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "kitchen",
            wakeMappings: [mapping],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: "family"
        )
        let initialState = DeviceConfigurationState(
            approvedDevice: approvedSetupDevice,
            verifiedConfiguration: verified,
            pendingConfiguration: nil,
            homeConfigurationRevision: 7,
            homeEligibility: .eligible,
            identityStatus: .verified
        )
        let disabledDevice = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "kitchen",
            wakeMappings: [mapping],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: "family",
            wakeClaimEnabled: false
        )
        let disabledSnapshot = HomeConfigurationSnapshot(
            revision: 8,
            wakeMappings: [CanonicalWakeMapping(id: mappingID, wakePhrase: "Hey Hermes")],
            devices: [disabledDevice],
            rooms: [HomeRoom(id: "kitchen", name: "Kitchen")]
        )
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient(),
            configurationStore: RejectingDeviceConfigurationStore(state: initialState),
            homeServiceClient: RecordingHomeServiceClient(
                fetchedSnapshot: disabledSnapshot,
                publishedSnapshot: disabledSnapshot
            )
        )

        await model.load()
        let reloadSucceeded = await model.reloadHomeConfiguration()

        XCTAssertFalse(reloadSucceeded)
        XCTAssertEqual(model.homeEligibility, .ineligible)
        XCTAssertFalse(model.isActive)
        XCTAssertTrue(model.errorMessage?.localizedCaseInsensitiveContains("could not be saved") == true)
    }

    func testHomeBackedReadyConfirmationPublishesThroughHomeService() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let mappingID = CanonicalWakeMappingID("hey-hermes")
        let mapping = DeviceWakeMapping(
            wakePhrase: "Hey Hermes",
            profileIdentifier: "family",
            canonicalID: mappingID
        )
        let currentDeviceConfiguration = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "kitchen",
            wakeMappings: [mapping],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: "family"
        )
        let currentHomeSnapshot = HomeConfigurationSnapshot(
            revision: 11,
            wakeMappings: [
                CanonicalWakeMapping(id: mappingID, wakePhrase: "Hey Hermes")
            ],
            devices: [currentDeviceConfiguration],
            rooms: [HomeRoom(id: "kitchen", name: "Kitchen")]
        )
        let homeClient = RecordingHomeServiceClient(
            fetchedSnapshot: currentHomeSnapshot,
            publishedSnapshot: currentHomeSnapshot
        )
        let administrationClient = FakeDeviceAdministrationClient()
        let setup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store,
            homeServiceClient: homeClient
        )
        await setup.loadDraft()
        setup.room = "Kitchen"
        XCTAssertTrue(setup.continueFromRoom())
        setup.wakeMappings = [mapping]
        XCTAssertTrue(setup.continueFromMappings())

        let completed = await setup.confirmReady()

        XCTAssertTrue(completed)
        XCTAssertEqual(setup.homeConfigurationRevision, 11)
        let expectedRevisions = await homeClient.publishExpectedRevisions()
        XCTAssertEqual(expectedRevisions, [11])
        let configurationCount = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCount, 0)
        let verificationCount = await administrationClient.verificationCount()
        XCTAssertEqual(verificationCount, 1)
        let persisted = try await store.load(for: approvedSetupDevice.id)
        XCTAssertEqual(persisted?.homeEligibility, .eligible)
    }

    func testSetupFallsBackToLegacyAdministrationOnlyWhenNoHomeRouteExists() async {
        let administrationClient = FakeDeviceAdministrationClient()
        let setup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            homeServiceClient: NoApprovedHomeRouteClient()
        )
        await setup.loadDraft()

        XCTAssertFalse(setup.isHomeBacked)
        setup.room = "Kitchen"
        XCTAssertTrue(setup.continueFromRoom())
        setup.wakeMappings = [
            DeviceWakeMapping(wakePhrase: "Hey Hermes", profileIdentifier: "family")
        ]
        XCTAssertTrue(setup.continueFromMappings())
        let completed = await setup.confirmReady()

        XCTAssertTrue(completed)
        let configurationCount = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCount, 1)
    }

    func testConfigurationEditorUsesLegacyAdministrationWhenHomeRouteIsAbsent() async throws {
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
        let administrationClient = FakeDeviceAdministrationClient()
        let model = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store,
            homeServiceClient: NoApprovedHomeRouteClient()
        )

        await model.load()
        XCTAssertFalse(model.isHomeBacked)
        model.room = "Study"
        let published = await model.publish()

        XCTAssertTrue(published)
        let configurationCount = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCount, 1)
        XCTAssertEqual(model.verifiedConfiguration.room, "Study")
    }

    func testConfiguredHomeFailureNeverFallsBackToLegacyAdministration() async {
        let administrationClient = FakeDeviceAdministrationClient()
        let setup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            homeServiceClient: FailingConfiguredHomeServiceClient(
                fetchError: .missingCredential
            )
        )

        await setup.loadDraft()

        XCTAssertTrue(setup.isHomeBacked)
        XCTAssertEqual(setup.errorMessage, HomeServiceError.missingCredential.userMessage)
        let configurationCount = await administrationClient.configurationCount()
        XCTAssertEqual(configurationCount, 0)
    }

    func testHomeBackedReadyDoesNotActivateWhenDeviceIdentityVerificationFails() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = JSONDeviceConfigurationStore(fileURL: fileURL)
        let mappingID = CanonicalWakeMappingID("hey-hermes")
        let mapping = DeviceWakeMapping(
            wakePhrase: "Hey Hermes",
            profileIdentifier: "family",
            canonicalID: mappingID
        )
        let homeDevice = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "kitchen",
            wakeMappings: [mapping],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: "family"
        )
        let snapshot = HomeConfigurationSnapshot(
            revision: 11,
            wakeMappings: [CanonicalWakeMapping(id: mappingID, wakePhrase: "Hey Hermes")],
            devices: [homeDevice],
            rooms: [HomeRoom(id: "kitchen", name: "Kitchen")]
        )
        let homeClient = RecordingHomeServiceClient(
            fetchedSnapshot: snapshot,
            publishedSnapshot: snapshot
        )
        let administrationClient = FakeDeviceAdministrationClient(
            verificationStatus: .unavailable
        )
        let setup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: administrationClient,
            configurationStore: store,
            homeServiceClient: homeClient
        )
        await setup.loadDraft()
        setup.room = "kitchen"
        XCTAssertTrue(setup.continueFromRoom())
        setup.wakeMappings = [mapping]
        XCTAssertTrue(setup.continueFromMappings())

        let completed = await setup.confirmReady()

        XCTAssertFalse(completed)
        XCTAssertFalse(setup.isActive)
        XCTAssertEqual(setup.step, .ready)
        let unactivatedState = try await store.load(for: approvedSetupDevice.id)
        XCTAssertNil(unactivatedState)
        let verificationCount = await administrationClient.verificationCount()
        XCTAssertEqual(verificationCount, 1)
    }

    func testHomeRoomIDsAndProfileIDsArePreservedVerbatim() async throws {
        let mappingID = CanonicalWakeMappingID("hey-hermes")
        let mapping = DeviceWakeMapping(
            wakePhrase: "Hey Hermes",
            profileIdentifier: " family ",
            canonicalID: mappingID
        )
        let homeDevice = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "kitchen",
            wakeMappings: [mapping],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: " family "
        )
        let selectedRoom = HomeRoom(id: " study ", name: "Study")
        let currentSnapshot = HomeConfigurationSnapshot(
            revision: 11,
            wakeMappings: [CanonicalWakeMapping(id: mappingID, wakePhrase: "Hey Hermes")],
            devices: [homeDevice],
            rooms: [HomeRoom(id: "kitchen", name: "Kitchen"), selectedRoom]
        )
        let publishedDevice = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: selectedRoom.id,
            wakeMappings: [mapping],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: " family "
        )
        let publishedSnapshot = HomeConfigurationSnapshot(
            revision: 12,
            wakeMappings: currentSnapshot.wakeMappings,
            devices: [publishedDevice],
            rooms: currentSnapshot.rooms
        )
        let homeClient = RecordingHomeServiceClient(
            fetchedSnapshot: currentSnapshot,
            publishedSnapshot: publishedSnapshot
        )
        let setup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient(),
            homeServiceClient: homeClient
        )
        await setup.loadDraft()
        setup.room = selectedRoom.id

        XCTAssertTrue(setup.continueFromRoom())
        XCTAssertEqual(setup.room, selectedRoom.id)
        setup.wakeMappings = [mapping]
        XCTAssertTrue(setup.continueFromMappings())
        XCTAssertEqual(setup.wakeMappings.first?.profileIdentifier, " family ")
        let completed = await setup.confirmReady()
        XCTAssertTrue(completed)

        let candidates = await homeClient.publishedCandidates()
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.devices.first?.room, selectedRoom.id)
        XCTAssertEqual(candidate.devices.first?.profileIdentifier, " family ")
        XCTAssertEqual(candidate.devices.first?.wakeMappings.first?.profileIdentifier, " family ")
    }

    func testEmptyHomeWakeMappingCatalogShowsHomeOwnedAction() async throws {
        let fileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let verified = DeviceSetupConfiguration(
            deviceID: approvedSetupDevice.id,
            room: "kitchen",
            wakeMappings: [],
            arbitrationPriority: 1,
            displayName: approvedSetupDevice.displayName,
            profileIdentifier: "family"
        )
        let snapshot = HomeConfigurationSnapshot(
            revision: 1,
            wakeMappings: [],
            devices: [verified],
            rooms: [HomeRoom(id: "kitchen", name: "Kitchen")]
        )
        let homeClient = RecordingHomeServiceClient(
            fetchedSnapshot: snapshot,
            publishedSnapshot: snapshot
        )
        let setup = DeviceSetupModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient(),
            homeServiceClient: homeClient
        )
        await setup.loadDraft()
        setup.room = "kitchen"
        XCTAssertTrue(setup.continueFromRoom())
        XCTAssertFalse(setup.continueFromMappings())
        XCTAssertTrue(setup.errorMessage?.contains("Home has no Wake Mappings") == true)

        try await JSONDeviceConfigurationStore(fileURL: fileURL).save(
            DeviceConfigurationState(
                approvedDevice: approvedSetupDevice,
                verifiedConfiguration: verified,
                pendingConfiguration: nil,
                homeConfigurationRevision: 1,
                homeEligibility: .eligible,
                identityStatus: .verified
            )
        )
        let edit = DeviceConfigurationModel(
            device: approvedSetupDevice,
            administrationClient: FakeDeviceAdministrationClient(),
            configurationStore: JSONDeviceConfigurationStore(fileURL: fileURL),
            homeServiceClient: homeClient
        )
        await edit.load()

        let published = await edit.publish()

        XCTAssertFalse(published)
        XCTAssertTrue(edit.errorMessage?.contains("Home has no Wake Mappings") == true)
    }

    func testHomeServiceMapsUnauthorizedAndTransportFailuresWithoutLeakingState() async {
        let unauthorizedTransport = RecordingHomeHTTPTransport(
            body: Data(#"{"schema":1,"error":{"code":"unauthorized"}}"#.utf8),
            statusCode: 401
        )
        let unauthorizedClient = URLSessionHomeServiceClient(
            baseURL: URL(string: "http://home.test")!,
            adminCredential: "home-admin-secret",
            transport: unauthorizedTransport
        )

        do {
            _ = try await unauthorizedClient.fetchConfiguration()
            XCTFail("Unauthorized Home access must fail closed")
        } catch let error as HomeServiceError {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertFalse(error.userMessage.contains("home-admin-secret"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let unavailableClient = URLSessionHomeServiceClient(
            baseURL: URL(string: "http://home.test")!,
            adminCredential: "home-admin-secret",
            transport: ThrowingHomeHTTPTransport()
        )
        do {
            _ = try await unavailableClient.fetchConfiguration()
            XCTFail("A transport failure must keep the Home state unavailable")
        } catch let error as HomeServiceError {
            XCTAssertEqual(error, .transportUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHomeServiceMapsStableErrorCodesAndUnknownCodesFailClosed() async {
        let cases: [(String, Int, HomeServiceError)] = [
            ("invalid_request", 400, .invalidRequest),
            ("unauthorized", 401, .unauthorized),
            ("not_found", 404, .notFound),
            ("revision_conflict", 409, .revisionConflict),
            ("service_unavailable", 503, .serviceUnavailable),
            ("future_code", 500, .invalidResponse)
        ]

        for (code, statusCode, expectedError) in cases {
            let transport = RecordingHomeHTTPTransport(
                body: Data(
                    #"{"schema":1,"error":{"code":"\#(code)"}}"#.utf8
                ),
                statusCode: statusCode
            )
            let client = URLSessionHomeServiceClient(
                baseURL: URL(string: "http://home.test")!,
                adminCredential: "home-admin-secret",
                transport: transport
            )

            do {
                _ = try await client.fetchConfiguration()
                XCTFail("Home error \(code) must not be treated as a successful fetch")
            } catch let error as HomeServiceError {
                XCTAssertEqual(error, expectedError, "Unexpected mapping for \(code)")
            } catch {
                XCTFail("Unexpected error for \(code): \(error)")
            }
        }
    }

    func testHomeServiceMapsRequestTimeoutSeparatelyFromUnavailableTransport() async {
        let client = URLSessionHomeServiceClient(
            baseURL: URL(string: "http://home.test")!,
            adminCredential: "home-admin-secret",
            transport: TimeoutHomeHTTPTransport()
        )

        do {
            _ = try await client.fetchConfiguration()
            XCTFail("A timed out Home request must fail")
        } catch let error as HomeServiceError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHomeAdminCredentialBindingRejectsAnyChangedApprovedRoute() async throws {
        let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let secureStore = HomeAdminCredentialSecureValueStore()
        let store = KeychainHomeAdminCredentialStore(secureStore: secureStore)
        let approvedRoute = homeAdminRoute()

        try await store.save(
            "home-admin-secret",
            for: profileID,
            approvedRoute: approvedRoute
        )

        let credentialForApprovedRoute = try await store.load(
            for: profileID,
            approvedRoute: approvedRoute
        )
        XCTAssertEqual(credentialForApprovedRoute, "home-admin-secret")

        for changedRoute in [
            homeAdminRoute(householdBinding: "household-b"),
            homeAdminRoute(host: "other-home.example"),
            homeAdminRoute(identityID: "another-home")
        ] {
            let credential = try await store.load(
                for: profileID,
                approvedRoute: changedRoute
            )
            XCTAssertNil(credential)
            let hasCredential = await store.hasCredential(
                for: profileID,
                approvedRoute: changedRoute
            )
            XCTAssertFalse(hasCredential)
        }
    }

    func testLegacyHomeAdminCredentialRecordRequiresReEntry() async throws {
        let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let secureStore = HomeAdminCredentialSecureValueStore()
        let store = KeychainHomeAdminCredentialStore(secureStore: secureStore)
        let key = "\(HomeAdminCredentialKeychain.service)/\(HomeAdminCredentialKeychain.account(for: profileID))"
        secureStore.values[key] = Data(
            """
            {"schemaVersion":1,"profileID":"\(profileID.uuidString)","householdBinding":"household-a","credential":"old-secret"}
            """.utf8
        )

        let credential = try await store.load(
            for: profileID,
            approvedRoute: homeAdminRoute()
        )
        XCTAssertNil(credential)
    }

    func testHomePublishNeverFabricatesRoomsForADevice() async {
        let mappingID = CanonicalWakeMappingID("wake")
        let configuration = HomeConfigurationSnapshot(
            revision: 1,
            wakeMappings: [CanonicalWakeMapping(id: mappingID, wakePhrase: "Hey Hermes")],
            devices: [
                DeviceSetupConfiguration(
                    deviceID: "device",
                    room: "kitchen",
                    wakeMappings: [
                        DeviceWakeMapping(
                            wakePhrase: "Hey Hermes",
                            profileIdentifier: "family",
                            canonicalID: mappingID
                        )
                    ],
                    arbitrationPriority: 1,
                    profileIdentifier: "family"
                )
            ]
        )
        let transport = RecordingHomeHTTPTransport(
            body: Data(#"{"schema":1,"snapshot":{"revision":2,"rooms":[],"wake_mappings":[],"devices":[]}}"#.utf8)
        )
        let client = URLSessionHomeServiceClient(
            baseURL: URL(string: "http://home.test")!,
            adminCredential: "home-admin-secret",
            transport: transport
        )

        do {
            _ = try await client.publish(configuration, expectedRevision: 1)
            XCTFail("A Device without a Home Room must not be serialized with a fabricated Room")
        } catch let error as HomeServiceError {
            XCTAssertEqual(error, .invalidConfiguration)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testHomeWireAcceptsOpaqueIdentifiersWithoutApplyingAnUndocumentedGrammar() async throws {
        let responseBody = Data(
            #"{"schema":1,"snapshot":{"revision":3,"rooms":[{"id":"room id","name":"Room"}],"wake_mappings":[{"id":"wake id","name":"Hey Hermes"}],"devices":[{"id":"device id","name":"Device","room_id":"room id","profile_id":"profile id","priority":1,"capabilities":{"wake_claim":true}}]}}"#.utf8
        )
        let client = URLSessionHomeServiceClient(
            baseURL: URL(string: "http://home.test")!,
            adminCredential: "home-admin-secret",
            transport: RecordingHomeHTTPTransport(body: responseBody)
        )

        let snapshot = try await client.fetchConfiguration()

        XCTAssertTrue(snapshot.isValid)
        XCTAssertEqual(snapshot.rooms.first?.id, "room id")
        XCTAssertEqual(snapshot.devices.first?.deviceID, "device id")
    }

    func testHomeWireRejectsWhitespaceOnlyIdentifiers() async {
        let responses = [
            #"{"schema":1,"snapshot":{"revision":1,"rooms":[{"id":"   ","name":"Kitchen"}],"wake_mappings":[{"id":"wake","name":"Hey Hermes"}],"devices":[{"id":"device","name":"Device","room_id":"   ","profile_id":"family","priority":1,"capabilities":{"wake_claim":true}}]}}"#,
            #"{"schema":1,"snapshot":{"revision":1,"rooms":[{"id":"kitchen","name":"Kitchen"}],"wake_mappings":[{"id":"   ","name":"Hey Hermes"}],"devices":[{"id":"device","name":"Device","room_id":"kitchen","profile_id":"family","priority":1,"capabilities":{"wake_claim":true}}]}}"#,
            #"{"schema":1,"snapshot":{"revision":1,"rooms":[{"id":"kitchen","name":"Kitchen"}],"wake_mappings":[{"id":"wake","name":"Hey Hermes"}],"devices":[{"id":"   ","name":"Device","room_id":"kitchen","profile_id":"family","priority":1,"capabilities":{"wake_claim":true}}]}}"#,
            #"{"schema":1,"snapshot":{"revision":1,"rooms":[{"id":"kitchen","name":"Kitchen"}],"wake_mappings":[{"id":"wake","name":"Hey Hermes"}],"devices":[{"id":"device","name":"Device","room_id":"kitchen","profile_id":"   ","priority":1,"capabilities":{"wake_claim":true}}]}}"#
        ]

        for response in responses {
            let client = URLSessionHomeServiceClient(
                baseURL: URL(string: "http://home.test")!,
                adminCredential: "home-admin-secret",
                transport: RecordingHomeHTTPTransport(body: Data(response.utf8))
            )
            do {
                _ = try await client.fetchConfiguration()
                XCTFail("Whitespace-only identifiers must be rejected")
            } catch let error as HomeServiceError {
                XCTAssertEqual(error, .invalidResponse)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHomeConfigurationReceiptRequiresEveryReturnedDeviceFieldAndRevision() {
        let mappingID = CanonicalWakeMappingID("wake")
        let mapping = DeviceWakeMapping(
            wakePhrase: "Hey Hermes",
            profileIdentifier: "family",
            canonicalID: mappingID
        )
        let requested = DeviceSetupConfiguration(
            deviceID: "device",
            room: "kitchen",
            wakeMappings: [mapping],
            arbitrationPriority: 1,
            displayName: "Kitchen Device",
            profileIdentifier: "family",
            wakeClaimEnabled: true
        )
        let receipt = DeviceConfigurationReceipt(
            deviceID: requested.deviceID,
            configuration: requested,
            homeConfigurationRevision: 8
        )

        XCTAssertTrue(receipt.matches(requested, minimumHomeRevision: 7))
        XCTAssertFalse(receipt.matches(requested, minimumHomeRevision: 9))
        XCTAssertFalse(
            receipt.matches(
                DeviceSetupConfiguration(
                    deviceID: "device",
                    room: "kitchen",
                    wakeMappings: [mapping],
                    arbitrationPriority: 1,
                    displayName: "Renamed Device",
                    profileIdentifier: "family",
                    wakeClaimEnabled: true
                )
            )
        )
        XCTAssertFalse(
            receipt.matches(
                DeviceSetupConfiguration(
                    deviceID: "device",
                    room: "kitchen",
                    wakeMappings: [mapping],
                    arbitrationPriority: 1,
                    displayName: "Kitchen Device",
                    profileIdentifier: "other",
                    wakeClaimEnabled: true
                )
            )
        )
        XCTAssertFalse(
            receipt.matches(
                DeviceSetupConfiguration(
                    deviceID: "device",
                    room: "kitchen",
                    wakeMappings: [mapping],
                    arbitrationPriority: 1,
                    displayName: "Kitchen Device",
                    profileIdentifier: "family",
                    wakeClaimEnabled: false
                )
            )
        )
    }

    func testHomeAdminCredentialStoreUsesDedicatedProfileScopedKeychainRecord() async throws {
        let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let secureStore = HomeAdminCredentialSecureValueStore()
        let store = KeychainHomeAdminCredentialStore(secureStore: secureStore)
        let approvedRoute = homeAdminRoute()

        try await store.save(
            "home-admin-secret",
            for: profileID,
            approvedRoute: approvedRoute
        )

        let key = "\(HomeAdminCredentialKeychain.service)/\(HomeAdminCredentialKeychain.account(for: profileID))"
        let recordData = try XCTUnwrap(secureStore.values[key])
        let record = try JSONDecoder().decode(
            HomeAdminCredentialKeychainRecord.self,
            from: recordData
        )
        XCTAssertEqual(record.profileID, profileID)
        XCTAssertEqual(record.approvedRoute, approvedRoute)
        XCTAssertEqual(record.credential, "home-admin-secret")
        XCTAssertNil(
            secureStore.values[
                "\(HomeCredentialKeychain.service)/\(HomeCredentialKeychain.account(for: profileID))"
            ]
        )
        let loadedCredential = try await store.load(
            for: profileID,
            approvedRoute: approvedRoute
        )
        XCTAssertEqual(loadedCredential, "home-admin-secret")
        let hasCredential = await store.hasCredential(
            for: profileID,
            approvedRoute: approvedRoute
        )
        XCTAssertTrue(hasCredential)

        try await store.delete(for: profileID)

        XCTAssertNil(secureStore.values[key])
        let hasCredentialAfterDelete = await store.hasCredential(
            for: profileID,
            approvedRoute: approvedRoute
        )
        XCTAssertFalse(hasCredentialAfterDelete)
    }

    func testHomeAdminCredentialFormPreservesBlankSaveAndRemovesExplicitly() async throws {
        let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let secureStore = HomeAdminCredentialSecureValueStore()
        let store = KeychainHomeAdminCredentialStore(secureStore: secureStore)
        let actions = HomeAdminCredentialFormActions(store: store)
        let route = homeAdminRoute()
        try await store.save("home-admin-secret", for: profileID, approvedRoute: route)

        let result = try await actions.save("  ", for: profileID, approvedRoute: route)

        XCTAssertEqual(result, .preserved)
        let preservedCredential = try await store.load(
            for: profileID,
            approvedRoute: route
        )
        XCTAssertEqual(preservedCredential, "home-admin-secret")

        try await actions.remove(for: profileID)
        let removedCredential = try await store.load(
            for: profileID,
            approvedRoute: route
        )
        XCTAssertNil(removedCredential)

        do {
            _ = try await actions.save("", for: profileID, approvedRoute: route)
            XCTFail("A blank Save without a matching stored credential must be rejected")
        } catch let error as HomeAdminCredentialStoreError {
            XCTAssertEqual(error, .emptyCredential)
        }
    }

    func testProfileHomeServiceClientUsesSelectedApprovedRouteAndAdminCredential() async throws {
        let profileURL = temporaryConfigurationFileURL()
        defer { try? FileManager.default.removeItem(at: profileURL.deletingLastPathComponent()) }
        let secureStore = HomeAdminCredentialSecureValueStore()
        let configurationStore = RelayConfigurationStore(
            secureStore: secureStore,
            profileURL: profileURL
        )
        let profile = try RelayProfile(
            endpoint: URL(string: "wss://relay.example/socket")!,
            clientID: "client",
            deviceID: "device",
            displayName: "Test Profile"
        )
        try await configurationStore.saveProfile(profile)

        let routeStore = JSONHomeLiveConfigurationStore(
            fileURL: profileURL.deletingLastPathComponent()
                .appendingPathComponent("home-live.json")
        )
        let route = HomeApprovedRoute(
            endpoint: URL(string: "wss://home.example/api/v1/bridge/ws")!,
            identity: HomeRouteIdentity(routeClass: .home, id: "home"),
            householdBinding: "household"
        )
        try await routeStore.save(
            try HomeLiveConfiguration(
                profileID: profile.id,
                conversationHandle: "handle",
                approvedRoute: route
            )
        )
        let adminStore = KeychainHomeAdminCredentialStore(secureStore: secureStore)
        try await adminStore.save(
            "home-admin-secret",
            for: profile.id,
            approvedRoute: route
        )
        let transport = RecordingHomeHTTPTransport(
            body: Data(
                #"{"schema":1,"snapshot":{"revision":4,"rooms":[{"id":"kitchen","name":"Kitchen"}],"wake_mappings":[{"id":"hey-hermes","name":"Hey Hermes"}],"devices":[{"id":"puck-kitchen","name":"Kitchen Puck","room_id":"kitchen","profile_id":"family","priority":1,"capabilities":{"wake_claim":true}}]}}"#.utf8
            )
        )
        let client = ProfileHomeServiceClient(
            configurationStore: configurationStore,
            routeProvider: routeStore,
            adminCredentialStore: adminStore,
            transport: transport
        )

        let hasRoute = try await client.hasApprovedRoute()
        XCTAssertTrue(hasRoute)

        _ = try await client.fetchConfiguration()

        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://home.example/api/v1/configuration")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer home-admin-secret")

        let changedRoute = HomeApprovedRoute(
            endpoint: route.endpoint,
            identity: route.identity,
            householdBinding: "different-household"
        )
        try await routeStore.save(
            try HomeLiveConfiguration(
                profileID: profile.id,
                conversationHandle: "handle",
                approvedRoute: changedRoute
            )
        )
        do {
            _ = try await client.fetchConfiguration()
            XCTFail("A credential bound to the old household must not follow a changed route")
        } catch let error as HomeServiceError {
            XCTAssertEqual(error, .missingCredential)
        }

        let changedEndpoint = HomeApprovedRoute(
            endpoint: URL(string: "wss://other-home.example/api/v1/bridge/ws")!,
            identity: route.identity,
            householdBinding: route.householdBinding
        )
        try await routeStore.save(
            try HomeLiveConfiguration(
                profileID: profile.id,
                conversationHandle: "handle",
                approvedRoute: changedEndpoint
            )
        )
        do {
            _ = try await client.fetchConfiguration()
            XCTFail("A credential must not follow an endpoint change with the same household label")
        } catch let error as HomeServiceError {
            XCTAssertEqual(error, .missingCredential)
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testHomeConfigurationSnapshotAcceptsSharedMappingAndUniqueRoomPriorities() {
        let mappingID = CanonicalWakeMappingID("wake-missy")
        let snapshot = HomeConfigurationSnapshot(
            revision: 7,
            wakeMappings: [
                CanonicalWakeMapping(id: mappingID, wakePhrase: "Hey Missy")
            ],
            devices: [
                DeviceSetupConfiguration(
                    deviceID: "kitchen-puck",
                    room: "Kitchen",
                    wakeMappings: [
                        DeviceWakeMapping(
                            wakePhrase: "Hey Missy",
                            profileIdentifier: "kitchen",
                            canonicalID: mappingID
                        )
                    ],
                    arbitrationPriority: 1
                ),
                DeviceSetupConfiguration(
                    deviceID: "kitchen-ipad",
                    room: "Kitchen",
                    wakeMappings: [
                        DeviceWakeMapping(
                            wakePhrase: "Hey Missy",
                            profileIdentifier: "hallway",
                            canonicalID: mappingID
                        )
                    ],
                    arbitrationPriority: 2
                )
            ]
        )

        XCTAssertTrue(snapshot.isValid)
        XCTAssertTrue(snapshot.validationErrors.isEmpty)
    }

    func testHomeConfigurationReplacementResolvesRoomNamesAndCanonicalMappings() throws {
        let mappingID = CanonicalWakeMappingID("hey-hermes")
        let currentDevice = DeviceSetupConfiguration(
            deviceID: "puck-kitchen",
            room: "kitchen",
            wakeMappings: [
                DeviceWakeMapping(
                    wakePhrase: "Hey Hermes",
                    profileIdentifier: "family",
                    canonicalID: mappingID
                )
            ],
            arbitrationPriority: 1,
            displayName: "Kitchen Puck",
            profileIdentifier: "family"
        )
        let snapshot = HomeConfigurationSnapshot(
            revision: 3,
            wakeMappings: [CanonicalWakeMapping(id: mappingID, wakePhrase: "Hey Hermes")],
            devices: [currentDevice],
            rooms: [HomeRoom(id: "kitchen", name: "Kitchen")]
        )
        let localEdit = DeviceSetupConfiguration(
            deviceID: currentDevice.deviceID,
            room: " kitchen ",
            wakeMappings: [
                DeviceWakeMapping(
                    wakePhrase: " hey   hermes ",
                    profileIdentifier: "family"
                )
            ]
        )

        let candidate = try XCTUnwrap(
            snapshot.replacingDevice(localEdit, preservingHomeMetadata: true)
        )
        let candidateDevice = try XCTUnwrap(candidate.devices.first)
        let candidateMapping = try XCTUnwrap(candidateDevice.wakeMappings.first)

        XCTAssertEqual(candidateDevice.room, "kitchen")
        XCTAssertEqual(candidateMapping.canonicalID, mappingID)
        XCTAssertEqual(candidateMapping.wakePhrase, " hey   hermes ")
    }

    func testHomeConfigurationSnapshotRejectsDuplicatePriorityWithinRoom() {
        let mappingID = CanonicalWakeMappingID("wake-missy")
        let mapping = CanonicalWakeMapping(id: mappingID, wakePhrase: "Hey Missy")
        let deviceMapping = DeviceWakeMapping(
            wakePhrase: "Hey Missy",
            profileIdentifier: "missy",
            canonicalID: mappingID
        )
        let snapshot = HomeConfigurationSnapshot(
            revision: 1,
            wakeMappings: [mapping],
            devices: [
                DeviceSetupConfiguration(
                    deviceID: "device-a",
                    room: "Kitchen",
                    wakeMappings: [deviceMapping],
                    arbitrationPriority: 1
                ),
                DeviceSetupConfiguration(
                    deviceID: "device-b",
                    room: " Kitchen ",
                    wakeMappings: [deviceMapping],
                    arbitrationPriority: 1
                )
            ]
        )

        XCTAssertTrue(
            snapshot.validationErrors.contains(
                .duplicatePriority(room: "Kitchen", priority: 1)
            )
        )
    }

    func testHomeConfigurationSnapshotRejectsUnknownOrMissingCanonicalMapping() {
        let knownID = CanonicalWakeMappingID("known")
        let unknownID = CanonicalWakeMappingID("unknown")
        let snapshot = HomeConfigurationSnapshot(
            revision: 1,
            wakeMappings: [
                CanonicalWakeMapping(id: knownID, wakePhrase: "Hey Missy")
            ],
            devices: [
                DeviceSetupConfiguration(
                    deviceID: "device-a",
                    room: "Kitchen",
                    wakeMappings: [
                        DeviceWakeMapping(
                            wakePhrase: "Hey Missy",
                            profileIdentifier: "missy"
                        ),
                        DeviceWakeMapping(
                            wakePhrase: "Hey River",
                            profileIdentifier: "river",
                            canonicalID: unknownID
                        )
                    ],
                    arbitrationPriority: 1
                )
            ]
        )

        XCTAssertTrue(
            snapshot.validationErrors.contains(
                .invalidDeviceMapping(deviceID: "device-a", mappingID: CanonicalWakeMappingID(""))
            )
        )
        XCTAssertTrue(
            snapshot.validationErrors.contains(
                .unknownMapping(deviceID: "device-a", mappingID: unknownID)
            )
        )
    }

    func testHomeConfigurationSnapshotRejectsMappingPhraseThatDisagreesWithCanonicalDefinition() {
        let mappingID = CanonicalWakeMappingID("wake-missy")
        let snapshot = HomeConfigurationSnapshot(
            revision: 1,
            wakeMappings: [
                CanonicalWakeMapping(id: mappingID, wakePhrase: "Hey Missy")
            ],
            devices: [
                DeviceSetupConfiguration(
                    deviceID: "device-a",
                    room: "Kitchen",
                    wakeMappings: [
                        DeviceWakeMapping(
                            wakePhrase: "Hey River",
                            profileIdentifier: "missy",
                            canonicalID: mappingID
                        )
                    ],
                    arbitrationPriority: 1
                )
            ]
        )

        XCTAssertTrue(
            snapshot.validationErrors.contains(
                .mappingPhraseMismatch(deviceID: "device-a", mappingID: mappingID)
            )
        )
    }

    func testHomeConfigurationSnapshotRejectsMultipleProfilesAndProfileMismatch() {
        let firstID = CanonicalWakeMappingID("wake-one")
        let secondID = CanonicalWakeMappingID("wake-two")
        let snapshot = HomeConfigurationSnapshot(
            revision: 4,
            wakeMappings: [
                CanonicalWakeMapping(id: firstID, wakePhrase: "Hey Hermes"),
                CanonicalWakeMapping(id: secondID, wakePhrase: "Hello Hermes")
            ],
            devices: [
                DeviceSetupConfiguration(
                    deviceID: "device-a",
                    room: "kitchen",
                    wakeMappings: [
                        DeviceWakeMapping(
                            wakePhrase: "Hey Hermes",
                            profileIdentifier: "family",
                            canonicalID: firstID
                        ),
                        DeviceWakeMapping(
                            wakePhrase: "Hello Hermes",
                            profileIdentifier: "personal",
                            canonicalID: secondID
                        )
                    ],
                    arbitrationPriority: 1,
                    displayName: "Kitchen Device",
                    profileIdentifier: "other"
                )
            ],
            rooms: [HomeRoom(id: "kitchen", name: "Kitchen")]
        )

        XCTAssertFalse(snapshot.isValid)
        XCTAssertTrue(snapshot.validationErrors.contains(.multipleProfiles(deviceID: "device-a")))
        XCTAssertTrue(snapshot.validationErrors.contains(.profileMismatch(deviceID: "device-a", profileID: "other")))
        XCTAssertFalse(snapshot.isCompleteHomeSnapshot)
    }

    func testHomeConfigurationSnapshotRoundTripsRevisionAndCanonicalIDs() throws {
        let mappingID = CanonicalWakeMappingID("wake-missy")
        let snapshot = HomeConfigurationSnapshot(
            revision: 12,
            wakeMappings: [
                CanonicalWakeMapping(id: mappingID, wakePhrase: "Hey Missy")
            ],
            devices: [
                DeviceSetupConfiguration(
                    deviceID: "device-a",
                    room: "Kitchen",
                    wakeMappings: [
                        DeviceWakeMapping(
                            wakePhrase: "Hey Missy",
                            profileIdentifier: "missy",
                            canonicalID: mappingID
                        )
                    ],
                    arbitrationPriority: 1
                )
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(HomeConfigurationSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
    }
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
    let revocationError: DeviceAdministrationError?
    let reEnrollmentError: DeviceAdministrationError?
    let verificationError: DeviceAdministrationError?
    let approvalReceiptDeviceID: String?
    let revocationReceiptDeviceID: String?
    let reEnrollmentReceiptDeviceID: String?
    let configurationReceiptDeviceID: String?
    let configurationReceipt: DeviceSetupConfiguration?
    let verificationReceiptDeviceID: String?
    let verificationStatus: DeviceIdentityStatus
    let verificationStatusByDeviceID: [String: DeviceIdentityStatus]
    let verificationConfiguration: DeviceSetupConfiguration?
    private var approvals = 0
    private var revocations = 0
    private var reEnrollments = 0
    private var configurations: [DeviceSetupConfiguration] = []
    private var verifications = 0

    init(
        approvalError: DeviceAdministrationError? = nil,
        configurationError: DeviceAdministrationError? = nil,
        revocationError: DeviceAdministrationError? = nil,
        reEnrollmentError: DeviceAdministrationError? = nil,
        verificationError: DeviceAdministrationError? = nil,
        approvalReceiptDeviceID: String? = nil,
        revocationReceiptDeviceID: String? = nil,
        reEnrollmentReceiptDeviceID: String? = nil,
        configurationReceiptDeviceID: String? = nil,
        configurationReceipt: DeviceSetupConfiguration? = nil,
        verificationReceiptDeviceID: String? = nil,
        verificationStatus: DeviceIdentityStatus = .verified,
        verificationStatusByDeviceID: [String: DeviceIdentityStatus] = [:],
        verificationConfiguration: DeviceSetupConfiguration? = nil
    ) {
        self.approvalError = approvalError
        self.configurationError = configurationError
        self.revocationError = revocationError
        self.reEnrollmentError = reEnrollmentError
        self.verificationError = verificationError
        self.approvalReceiptDeviceID = approvalReceiptDeviceID
        self.revocationReceiptDeviceID = revocationReceiptDeviceID
        self.reEnrollmentReceiptDeviceID = reEnrollmentReceiptDeviceID
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

    func revoke(_ device: HouseholdDevice) async throws -> DeviceRevocationReceipt {
        revocations += 1
        if let revocationError {
            throw revocationError
        }
        return DeviceRevocationReceipt(deviceID: revocationReceiptDeviceID ?? device.id)
    }

    func reEnroll(_ device: HouseholdDevice) async throws -> DeviceReenrollmentReceipt {
        reEnrollments += 1
        if let reEnrollmentError {
            throw reEnrollmentError
        }
        return DeviceReenrollmentReceipt(deviceID: reEnrollmentReceiptDeviceID ?? device.id)
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

    func revocationCount() -> Int {
        revocations
    }

    func reEnrollmentCount() -> Int {
        reEnrollments
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

private actor RecordingHomeHTTPTransport: HomeHTTPTransport {
    private let body: Data
    private let response: HomeHTTPResponse
    private var requests: [URLRequest] = []

    init(body: Data, statusCode: Int = 200) {
        self.body = body
        response = HomeHTTPResponse(statusCode: statusCode)
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HomeHTTPResponse) {
        requests.append(request)
        return (body, response)
    }

    func lastRequest() -> URLRequest? {
        requests.last
    }

    func requestCount() -> Int {
        requests.count
    }
}

private struct ThrowingHomeHTTPTransport: HomeHTTPTransport {
    func data(
        for request: URLRequest
    ) async throws -> (Data, HomeHTTPResponse) {
        throw URLError(.cannotConnectToHost)
    }
}

private struct TimeoutHomeHTTPTransport: HomeHTTPTransport {
    func data(
        for request: URLRequest
    ) async throws -> (Data, HomeHTTPResponse) {
        throw URLError(.timedOut)
    }
}

private final class HomeAdminCredentialSecureValueStore: SecureValueStore, @unchecked Sendable {
    var values: [String: Data] = [:]

    func read(service: String, account: String) throws -> Data? {
        values["\(service)/\(account)"]
    }

    func write(_ value: Data, service: String, account: String) throws {
        values["\(service)/\(account)"] = value
    }

    func delete(service: String, account: String) throws {
        values.removeValue(forKey: "\(service)/\(account)")
    }
}

private actor RecordingHomeServiceClient: HomeServiceClient {
    private let fetchedSnapshot: HomeConfigurationSnapshot
    private let publishedSnapshot: HomeConfigurationSnapshot
    private var expectedRevisions: [Int] = []
    private var candidates: [HomeConfigurationSnapshot] = []

    init(
        fetchedSnapshot: HomeConfigurationSnapshot,
        publishedSnapshot: HomeConfigurationSnapshot
    ) {
        self.fetchedSnapshot = fetchedSnapshot
        self.publishedSnapshot = publishedSnapshot
    }

    func fetchConfiguration() async throws -> HomeConfigurationSnapshot {
        fetchedSnapshot
    }

    func publish(
        _ configuration: HomeConfigurationSnapshot,
        expectedRevision: Int
    ) async throws -> HomeConfigurationSnapshot {
        expectedRevisions.append(expectedRevision)
        candidates.append(configuration)
        return publishedSnapshot
    }

    func publishExpectedRevisions() -> [Int] {
        expectedRevisions
    }

    func publishedCandidates() -> [HomeConfigurationSnapshot] {
        candidates
    }
}

private struct NoApprovedHomeRouteClient: HomeServiceClient {
    func hasApprovedRoute() async throws -> Bool { false }

    func fetchConfiguration() async throws -> HomeConfigurationSnapshot {
        throw HomeServiceError.notConfigured
    }

    func publish(
        _ configuration: HomeConfigurationSnapshot,
        expectedRevision: Int
    ) async throws -> HomeConfigurationSnapshot {
        throw HomeServiceError.notConfigured
    }
}

private struct FailingConfiguredHomeServiceClient: HomeServiceClient {
    let fetchError: HomeServiceError

    func hasApprovedRoute() async throws -> Bool { true }

    func fetchConfiguration() async throws -> HomeConfigurationSnapshot {
        throw fetchError
    }

    func publish(
        _ configuration: HomeConfigurationSnapshot,
        expectedRevision: Int
    ) async throws -> HomeConfigurationSnapshot {
        throw fetchError
    }
}

private struct FailingPublishHomeServiceClient: HomeServiceClient {
    let snapshot: HomeConfigurationSnapshot
    let publishError: HomeServiceError

    func fetchConfiguration() async throws -> HomeConfigurationSnapshot {
        snapshot
    }

    func publish(
        _ configuration: HomeConfigurationSnapshot,
        expectedRevision: Int
    ) async throws -> HomeConfigurationSnapshot {
        throw publishError
    }
}

private actor RejectingDeviceConfigurationStore: DeviceConfigurationStore {
    private let state: DeviceConfigurationState

    init(state: DeviceConfigurationState) {
        self.state = state
    }

    func loadAll() async throws -> [DeviceConfigurationState] {
        [state]
    }

    func save(_ state: DeviceConfigurationState) async throws {
        throw HomeServiceError.transportUnavailable
    }
}

private final class RedirectRequestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?
    private var callbackWasCalled = false

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return callbackWasCalled
    }

    func record(_ request: URLRequest?) {
        lock.lock()
        storedRequest = request
        callbackWasCalled = true
        lock.unlock()
    }
}

private actor SequencedHomeServiceClient: HomeServiceClient {
    private let snapshots: [HomeConfigurationSnapshot]
    private var fetchIndex = 0

    init(snapshots: [HomeConfigurationSnapshot]) {
        self.snapshots = snapshots
    }

    func fetchConfiguration() async throws -> HomeConfigurationSnapshot {
        guard !snapshots.isEmpty else {
            throw HomeServiceError.invalidResponse
        }
        let index = min(fetchIndex, snapshots.count - 1)
        fetchIndex += 1
        return snapshots[index]
    }

    func publish(
        _ configuration: HomeConfigurationSnapshot,
        expectedRevision: Int
    ) async throws -> HomeConfigurationSnapshot {
        throw HomeServiceError.invalidResponse
    }
}

private struct ConflictingHomeServiceClient: HomeServiceClient {
    let snapshot: HomeConfigurationSnapshot

    func fetchConfiguration() async throws -> HomeConfigurationSnapshot {
        snapshot
    }

    func publish(
        _ configuration: HomeConfigurationSnapshot,
        expectedRevision: Int
    ) async throws -> HomeConfigurationSnapshot {
        throw HomeServiceError.revisionConflict
    }
}
