import Foundation
import XCTest
@testable import HermesRelayIOS

final class HomeConfigurationMigrationTests: XCTestCase {
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
