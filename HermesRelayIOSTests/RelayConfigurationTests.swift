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
