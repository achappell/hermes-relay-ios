import Foundation
import XCTest
@testable import HermesRelayIOS

final class HomeConfigurationMigrationTests: XCTestCase {
    func testAppFactoryUsesTheLiveFactoryWhenTheDebugFakeIsDisabled() async throws {
        let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let claim = HomeDemoFixtures.claim(for: profileID)
        let liveClient = FakeHomeBridgeSessionClient(claim: claim)
        let factory = AppHomeBridgeSessionClientFactory(
            enabled: false,
            claimProvider: AppHomeConversationClaimProvider(),
            liveFactory: FakeHomeBridgeSessionClientFactory(client: liveClient)
        )

        let client = factory.make(profileID: profileID, mode: .home)

        guard let typedClient = client as? FakeHomeBridgeSessionClient else {
            return XCTFail("A configured live factory must be used when the fake is disabled")
        }
        guard case .ready = await typedClient.open(claim: claim) else {
            return XCTFail("The injected live client must remain usable")
        }
    }

    func testLiveConfigurationRoundTripsClaimMetadataWithoutADeviceSecret() async throws {
        let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let route = HomeApprovedRoute(
            endpoint: URL(string: "wss://home.example/api/v1/bridge/ws")!,
            identity: HomeRouteIdentity(routeClass: .home, id: "local"),
            householdBinding: "household-a"
        )
        let configuration = try HomeLiveConfiguration(
            profileID: profileID,
            conversationHandle: "opaque-home-conversation",
            approvedRoute: route
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesHomeLive-" + UUID().uuidString)
            .appendingPathExtension("json")
        let store = JSONHomeLiveConfigurationStore(fileURL: fileURL)

        try await store.save(configuration)

        let loaded = try await store.configuration(for: profileID)
        let loadedClaim = try await store.conversationClaim(for: profileID)
        let expectedClaim = try configuration.claim(for: profileID)
        XCTAssertEqual(loaded, configuration)
        XCTAssertEqual(loadedClaim, expectedClaim)
        let saved = try Data(contentsOf: fileURL)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("credential"))
        XCTAssertFalse(saved.contains(Data("device-secret".utf8)))
    }

    func testCredentialReferenceAcceptsOnlyItsOwnersAccountInBothFormats() throws {
        let owner = UUID()
        let other = UUID()
        let expiresAt = Date(timeIntervalSince1970: 1_000 + 90 * 24 * 60 * 60)
        func reference(service: String = HomeCredentialKeychain.service, account: String) -> HomeCredentialReference {
            HomeCredentialReference(
                service: service,
                account: account,
                issuedAt: Date(timeIntervalSince1970: 1_000),
                expiresAt: expiresAt,
                renewAfter: expiresAt.addingTimeInterval(-14 * 24 * 60 * 60),
                overlapUntil: nil
            )
        }

        XCTAssertNoThrow(try reference(account: HomeCredentialKeychain.account(for: owner)).validate(for: owner))
        XCTAssertNoThrow(try reference(account: HomeCredentialKeychain.account(forPairing: owner)).validate(for: owner))
        for rejected in [
            reference(account: HomeCredentialKeychain.account(for: other)),
            reference(account: HomeCredentialKeychain.account(forPairing: other)),
            reference(service: "com.example.other", account: HomeCredentialKeychain.account(for: owner)),
        ] {
            XCTAssertThrowsError(try rejected.validate(for: owner)) {
                XCTAssertEqual($0 as? HomeCredentialReferenceError, .wrongServiceOrAccount)
            }
        }
    }

    func testCredentialProvisioningStoresTheSecretSeparatelyFromReferenceMetadata() async throws {
        let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        let expiresAt = issuedAt.addingTimeInterval(90 * 24 * 60 * 60)
        let reference = HomeCredentialReference(
            service: HomeCredentialKeychain.service,
            account: HomeCredentialKeychain.account(for: profileID),
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            renewAfter: expiresAt.addingTimeInterval(-14 * 24 * 60 * 60),
            overlapUntil: nil
        )
        let secureStore = MigrationSecureValueStore()
        let store = KeychainHomeCredentialStore(secureStore: secureStore)

        try await store.provision(
            preIssuedCredential: Data("device-secret".utf8),
            reference: reference,
            for: profileID
        )

        XCTAssertEqual(
            try secureStore.read(
                service: reference.service,
                account: reference.account
            ),
            Data("device-secret".utf8)
        )
        let metadata = try XCTUnwrap(
            try secureStore.read(
                service: HomeCredentialKeychain.service,
                account: "reference." + profileID.uuidString
            )
        )
        XCTAssertFalse(metadata.contains(Data("device-secret".utf8)))
        XCTAssertEqual(
            try JSONDecoder().decode(HomeCredentialReference.self, from: metadata),
            reference
        )
    }

    func testLiveActivationProvesTheRealFactoryBeforeSelectingHome() async throws {
        let fixture = try await makeFixture()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesHomeLive-" + UUID().uuidString)
            .appendingPathExtension("json")
        let liveStore = JSONHomeLiveConfigurationStore(fileURL: fileURL)
        let activation = HomeLiveActivation(
            configurationStore: fixture.configurationStore,
            credentialStore: fixture.credentialStore,
            liveConfigurationStore: liveStore,
            homeClientFactory: FakeHomeBridgeSessionClientFactory(client: fixture.client),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let configuration = try HomeLiveConfiguration(
            profileID: fixture.profile.id,
            conversationHandle: fixture.claim.conversationHandle,
            approvedRoute: fixture.claim.approvedRoute
        )

        let result = try await activation.activate(
            profileID: fixture.profile.id,
            liveConfiguration: configuration,
            deviceCredential: Data("device-secret".utf8)
        )

        XCTAssertEqual(result, .selectedHome)
        let selectedMode = try await fixture.configurationStore.transportMode(
            for: fixture.profile.id
        )
        let openCount = await fixture.client.openCount
        XCTAssertEqual(selectedMode, .home)
        XCTAssertEqual(openCount, 1)
    }

    func testLiveMigrationRecordsLiveReadinessBeforeSelectingHome() async throws {
        let fixture = try await makeFixture()
        let migration = HomeConfigurationMigration(
            configurationStore: fixture.configurationStore,
            credentialStore: fixture.credentialStore,
            pairingHandoff: FakeHomePairingCredentialHandoff(reference: fixture.reference),
            claimProvider: StaticHomeConversationClaimProvider(claim: fixture.claim),
            homeClientFactory: FakeHomeBridgeSessionClientFactory(client: fixture.client),
            readiness: .live
        )

        let result = try await migration.migrate(profileID: fixture.profile.id)

        XCTAssertEqual(result, .selectedHome)
        let journal = try await fixture.configurationStore.loadHomeMigration(
            for: fixture.profile.id
        )
        XCTAssertEqual(journal?.phase, .homeSelected)
    }

    func testLiveActivationCanReuseAnExistingKeychainCredential() async throws {
        let fixture = try await makeFixture()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesHomeLive-" + UUID().uuidString)
            .appendingPathExtension("json")
        let liveStore = JSONHomeLiveConfigurationStore(fileURL: fileURL)
        let activation = HomeLiveActivation(
            configurationStore: fixture.configurationStore,
            credentialStore: fixture.credentialStore,
            liveConfigurationStore: liveStore,
            homeClientFactory: FakeHomeBridgeSessionClientFactory(client: fixture.client),
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        let configuration = try HomeLiveConfiguration(
            profileID: fixture.profile.id,
            conversationHandle: fixture.claim.conversationHandle,
            approvedRoute: fixture.claim.approvedRoute
        )

        let result = try await activation.activate(
            profileID: fixture.profile.id,
            liveConfiguration: configuration,
            deviceCredential: Data()
        )

        XCTAssertEqual(result, .selectedHome)
        let openCount = await fixture.client.openCount
        XCTAssertEqual(openCount, 1)
        let journal = try await fixture.configurationStore.loadHomeMigration(
            for: fixture.profile.id
        )
        XCTAssertEqual(journal?.credential, fixture.reference)
    }

    func testLiveActivationKeepsLegacyWhenTheLiveHandshakeFails() async throws {
        let fixture = try await makeFixture()
        await fixture.client.setNextOpenFailure(.publicAdapterUnavailable)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesHomeLive-" + UUID().uuidString)
            .appendingPathExtension("json")
        let liveStore = JSONHomeLiveConfigurationStore(fileURL: fileURL)
        let activation = HomeLiveActivation(
            configurationStore: fixture.configurationStore,
            credentialStore: fixture.credentialStore,
            liveConfigurationStore: liveStore,
            homeClientFactory: FakeHomeBridgeSessionClientFactory(client: fixture.client)
        )
        let configuration = try HomeLiveConfiguration(
            profileID: fixture.profile.id,
            conversationHandle: fixture.claim.conversationHandle,
            approvedRoute: fixture.claim.approvedRoute
        )

        do {
            _ = try await activation.activate(
                profileID: fixture.profile.id,
                liveConfiguration: configuration,
                deviceCredential: Data("device-secret".utf8)
            )
            XCTFail("A failed live handshake must not select Home")
        } catch let error as HomeLiveActivationError {
            XCTAssertEqual(error, .handshakeFailed)
        }

        let journal = try await fixture.configurationStore.loadHomeMigration(
            for: fixture.profile.id
        )
        XCTAssertEqual(journal?.phase, .legacySelected)
        XCTAssertEqual(journal?.selectedMode, .legacy)
    }

    func testMigrationKeepsLegacyCredentialUntilFakeReadyThenSelectsHome() async throws {
        let fixture = try await makeFixture()
        let migration = HomeConfigurationMigration(
            configurationStore: fixture.configurationStore,
            credentialStore: fixture.credentialStore,
            pairingHandoff: FakeHomePairingCredentialHandoff(reference: fixture.reference),
            claimProvider: StaticHomeConversationClaimProvider(claim: fixture.claim),
            homeClientFactory: FakeHomeBridgeSessionClientFactory(client: fixture.client)
        )

        let migrationResult = try await migration.migrate(profileID: fixture.profile.id)
        XCTAssertEqual(migrationResult, .selectedHome)
        let journal = try await fixture.configurationStore.loadHomeMigration(
            for: fixture.profile.id
        )

        XCTAssertEqual(journal?.phase, .homeSelected)
        XCTAssertEqual(journal?.selectedMode, .home)
        XCTAssertTrue(journal?.legacyCredentialRetained == true)
        let selectedMode = try await fixture.configurationStore.transportMode(for: fixture.profile.id)
        XCTAssertEqual(selectedMode, .home)
        let legacyToken = try await fixture.configurationStore.loadToken(for: fixture.profile.id)
        XCTAssertEqual(legacyToken, "legacy-bearer")
        let openCount = await fixture.client.openCount
        XCTAssertEqual(openCount, 1)
    }

    func testFakeReadyFailureRollsTheJournalBackToLegacy() async throws {
        let fixture = try await makeFixture()
        await fixture.client.setNextOpenFailure(.publicAdapterUnavailable)
        let migration = HomeConfigurationMigration(
            configurationStore: fixture.configurationStore,
            credentialStore: fixture.credentialStore,
            pairingHandoff: FakeHomePairingCredentialHandoff(reference: fixture.reference),
            claimProvider: StaticHomeConversationClaimProvider(claim: fixture.claim),
            homeClientFactory: FakeHomeBridgeSessionClientFactory(client: fixture.client)
        )

        do {
            _ = try await migration.migrate(profileID: fixture.profile.id)
            XCTFail("A failed fake-ready check must not select Home")
        } catch let error as HomeConfigurationMigrationError {
            XCTAssertEqual(error, .fakeReadyFailed)
        }

        let journal = try await fixture.configurationStore.loadHomeMigration(
            for: fixture.profile.id
        )
        XCTAssertEqual(journal?.phase, .legacySelected)
        XCTAssertEqual(journal?.selectedMode, .legacy)
        let selectedMode = try await fixture.configurationStore.transportMode(for: fixture.profile.id)
        XCTAssertEqual(selectedMode, .legacy)
        let legacyToken = try await fixture.configurationStore.loadToken(for: fixture.profile.id)
        XCTAssertEqual(legacyToken, "legacy-bearer")
    }

    func testCredentialLifecycleRejectsRenewalOutsideTheFourteenDayWindow() {
        let profileID = UUID()
        let issuedAt = Date(timeIntervalSince1970: 0)
        let expiresAt = issuedAt.addingTimeInterval(90 * 24 * 60 * 60)
        let reference = HomeCredentialReference(
            service: HomeCredentialKeychain.service,
            account: HomeCredentialKeychain.account(for: profileID),
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            renewAfter: issuedAt.addingTimeInterval(75 * 24 * 60 * 60),
            overlapUntil: nil
        )

        XCTAssertThrowsError(try reference.validate(for: profileID)) { error in
            XCTAssertEqual(error as? HomeCredentialReferenceError, .invalidLifecycleDates)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let profile = try RelayProfile(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            endpoint: URL(string: "wss://legacy.example/session")!,
            clientID: "hermes-apple",
            deviceID: "apple-device",
            displayName: "Test Apple"
        )
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesHomeMigration-(UUID().uuidString)")
            .appendingPathExtension("json")
        let secureStore = MigrationSecureValueStore()
        let configurationStore = RelayConfigurationStore(
            secureStore: secureStore,
            profileURL: profileURL
        )
        try await configurationStore.saveProfile(profile)
        try await configurationStore.saveToken("legacy-bearer", for: profile.id)

        let route = HomeApprovedRoute(
            endpoint: URL(string: "wss://home.example/api/v1/bridge/ws")!,
            identity: HomeRouteIdentity(routeClass: .home, id: "home-a"),
            householdBinding: "household-a"
        )
        let claim = HomeConversationClaim(
            profileID: profile.id,
            conversationHandle: "opaque-home-conversation",
            approvedRoute: route
        )
        let issuedAt = Date(timeIntervalSince1970: 0)
        let reference = HomeCredentialReference(
            service: HomeCredentialKeychain.service,
            account: HomeCredentialKeychain.account(for: profile.id),
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(90 * 24 * 60 * 60),
            renewAfter: issuedAt.addingTimeInterval(76 * 24 * 60 * 60),
            overlapUntil: nil
        )
        let credentialStore = InMemoryHomeCredentialStore()
        await credentialStore.seed(
            credential: Data("device-secret".utf8),
            reference: reference,
            for: profile.id
        )
        let client = FakeHomeBridgeSessionClient(claim: claim)
        return Fixture(
            profile: profile,
            configurationStore: configurationStore,
            credentialStore: credentialStore,
            reference: reference,
            claim: claim,
            client: client
        )
    }
}

private struct Fixture: Sendable {
    let profile: RelayProfile
    let configurationStore: RelayConfigurationStore
    let credentialStore: InMemoryHomeCredentialStore
    let reference: HomeCredentialReference
    let claim: HomeConversationClaim
    let client: FakeHomeBridgeSessionClient
}

private final class MigrationSecureValueStore: SecureValueStore, @unchecked Sendable {
    private var values: [String: Data] = [:]

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
