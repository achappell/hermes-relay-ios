import Foundation
import XCTest
@testable import HermesRelayIOS

final class RelayConfigurationTests: XCTestCase {
    func testMissingProfileIsExplicitlyUnconfigured() async throws {
        let store = RelayConfigurationStore(
            secureStore: FakeSecureValueStore(),
            profileURL: temporaryProfileURL()
        )

        let profile = try await store.loadProfile()

        XCTAssertNil(profile)
    }

    func testMalformedProfileIsReportedAsInvalidConfiguration() async throws {
        let profileURL = temporaryProfileURL()
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ not a relay profile }".utf8).write(to: profileURL, options: .atomic)
        let store = RelayConfigurationStore(
            secureStore: FakeSecureValueStore(),
            profileURL: profileURL
        )

        do {
            _ = try await store.loadProfile()
            XCTFail("Malformed profile data must be rejected")
        } catch let error as RelayConfigurationError {
            XCTAssertEqual(error, .invalidProfile)
        }
    }

    func testSavingAndLoadingProfileDoesNotRequireTheToken() async throws {
        let secureStore = FakeSecureValueStore()
        let store = RelayConfigurationStore(
            secureStore: secureStore,
            profileURL: temporaryProfileURL()
        )
        let expected = try RelayProfile(
            endpoint: URL(string: "wss://relay.example.test/session")!,
            clientID: "hermes-ios",
            deviceID: "device-123",
            displayName: "Amanda's iPhone"
        )

        try await store.saveProfile(expected)

        let actual = try await store.loadProfile()
        let token = try secureStore.read(service: "com.achappell.HermesRelayIOS.profile", account: "default-token")

        XCTAssertEqual(actual, expected)
        XCTAssertNil(token)
    }

    func testSavingAndLoadingTokenUsesTheSecureStore() async throws {
        let secureStore = FakeSecureValueStore()
        let store = RelayConfigurationStore(
            secureStore: secureStore,
            profileURL: temporaryProfileURL()
        )

        try await store.saveToken("token-value")

        let token = try await store.loadToken()

        XCTAssertEqual(token, "token-value")
        XCTAssertEqual(secureStore.lastReadService, "com.achappell.HermesRelayIOS.profile")
        XCTAssertEqual(secureStore.lastReadAccount, "default-token")
        XCTAssertEqual(secureStore.values["com.achappell.HermesRelayIOS.profile/default-token"], Data("token-value".utf8))
    }

    func testWhitespaceOnlyTokenIsRejected() async throws {
        let store = RelayConfigurationStore(
            secureStore: FakeSecureValueStore(),
            profileURL: temporaryProfileURL()
        )

        do {
            try await store.saveToken("  \n\t ")
            XCTFail("Whitespace-only tokens must not be stored")
        } catch let error as RelayConfigurationError {
            XCTAssertEqual(error, .emptyToken)
        }
    }

    func testEmptyStoredTokenIsRejected() async throws {
        let secureStore = FakeSecureValueStore()
        secureStore.values["com.achappell.HermesRelayIOS.profile/default-token"] = Data("  ".utf8)
        let store = RelayConfigurationStore(
            secureStore: secureStore,
            profileURL: temporaryProfileURL()
        )

        do {
            _ = try await store.loadToken()
            XCTFail("An empty stored token must not be treated as configured")
        } catch let error as RelayConfigurationError {
            XCTAssertEqual(error, .emptyToken)
        }
    }

    func testDeletingTokenLeavesTheProfileIntact() async throws {
        let store = RelayConfigurationStore(
            secureStore: FakeSecureValueStore(),
            profileURL: temporaryProfileURL()
        )
        let expected = try RelayProfile(
            endpoint: URL(string: "ws://localhost:8765")!,
            clientID: "hermes-ios",
            deviceID: "device-123",
            displayName: "Test Mac"
        )

        try await store.saveProfile(expected)
        try await store.saveToken("token-value")
        try await store.deleteToken()

        let profile = try await store.loadProfile()
        let token = try await store.loadToken()

        XCTAssertEqual(profile, expected)
        XCTAssertNil(token)
    }

    func testInvalidEndpointIsRejectedBeforeAClientIsBuilt() async throws {
        XCTAssertThrowsError(
            try RelayProfile(
                endpoint: URL(string: "https://relay.example.test/session")!,
                clientID: "hermes-ios",
                deviceID: "device-123",
                displayName: "Test Mac"
            )
        ) { error in
            XCTAssertEqual(error as? RelayProfileError, .unsupportedEndpointScheme)
        }
    }

    func testEndpointCredentialsAreRejectedBeforeProfileStorage() {
        XCTAssertThrowsError(
            try RelayProfile(
                endpoint: URL(string: "wss://user:password@relay.example.test/session")!,
                clientID: "hermes-ios",
                deviceID: "device-123",
                displayName: "Test iPhone"
            )
        ) { error in
            XCTAssertEqual(error as? RelayProfileError, .endpointContainsCredentials)
        }
    }

    func testConfigurationDraftLoadsProfileFieldsWithoutLoadingTheToken() throws {
        let profile = try RelayProfile(
            endpoint: URL(string: "wss://relay.example.test/session")!,
            clientID: "hermes-ios",
            deviceID: "device-123",
            displayName: "Amanda's iPhone"
        )

        let draft = RelayConfigurationDraft(profile: profile, hasStoredToken: true)

        XCTAssertEqual(draft.endpoint, "wss://relay.example.test/session")
        XCTAssertEqual(draft.clientID, "hermes-ios")
        XCTAssertEqual(draft.deviceID, "device-123")
        XCTAssertEqual(draft.displayName, "Amanda's iPhone")
        XCTAssertTrue(draft.hasStoredToken)
        XCTAssertTrue(draft.token.isEmpty)
    }

    func testConfigurationDraftUsesEditableDeviceIdentityDefaults() {
        let draft = RelayConfigurationDraft(
            identity: RelayDeviceIdentity(deviceName: "Amanda’s iPhone")
        )

        #if os(iOS)
        XCTAssertEqual(draft.clientID, "hermes-ios-amanda-s-iphone")
        #elseif os(macOS)
        XCTAssertEqual(draft.clientID, "hermes-mac-amanda-s-iphone")
        #else
        XCTAssertEqual(draft.clientID, "hermes-apple-amanda-s-iphone")
        #endif
        XCTAssertEqual(draft.deviceID, "amanda-s-iphone")
        XCTAssertEqual(draft.displayName, "Amanda’s iPhone")
    }

    func testConfigurationDraftBuildsTrimmedProfileAndToken() throws {
        var draft = RelayConfigurationDraft()
        draft.endpoint = "  wss://relay.example.test/session  "
        draft.clientID = "  hermes-ios "
        draft.deviceID = " device-123 "
        draft.displayName = " Amanda's iPhone "
        draft.token = " token-value "

        let profile = try draft.makeProfile()

        XCTAssertEqual(profile.endpoint.absoluteString, "wss://relay.example.test/session")
        XCTAssertEqual(profile.clientID, "hermes-ios")
        XCTAssertEqual(profile.deviceID, "device-123")
        XCTAssertEqual(profile.displayName, "Amanda's iPhone")
        XCTAssertEqual(try draft.tokenToSave(existingToken: nil), "token-value")
    }

    func testConfigurationDraftKeepsStoredTokenWhenInputIsBlank() throws {
        let draft = RelayConfigurationDraft(hasStoredToken: true)

        XCTAssertEqual(try draft.tokenToSave(existingToken: "stored-token"), "stored-token")
    }

    func testConfigurationDraftRequiresTokenWhenNoTokenIsStored() {
        let draft = RelayConfigurationDraft()

        XCTAssertThrowsError(try draft.tokenToSave(existingToken: nil)) { error in
            XCTAssertEqual(error as? RelayConfigurationFormError, .tokenRequired)
        }
    }

    func testConfigurationDraftRejectsAnEmptyEndpoint() {
        let draft = RelayConfigurationDraft()

        XCTAssertThrowsError(try draft.makeProfile()) { error in
            XCTAssertEqual(error as? RelayConfigurationFormError, .endpointRequired)
        }
    }

    private func temporaryProfileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesRelayIOS-\(UUID().uuidString)")
            .appendingPathComponent("profile.json")
    }
}

private final class FakeSecureValueStore: SecureValueStore, @unchecked Sendable {
    var values: [String: Data] = [:]
    var lastReadService: String?
    var lastReadAccount: String?

    func read(service: String, account: String) throws -> Data? {
        lastReadService = service
        lastReadAccount = account
        return values["\(service)/\(account)"]
    }

    func write(_ value: Data, service: String, account: String) throws {
        values["\(service)/\(account)"] = value
    }

    func delete(service: String, account: String) throws {
        values.removeValue(forKey: "\(service)/\(account)")
    }
}
