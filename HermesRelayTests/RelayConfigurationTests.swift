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
            displayName: "Test iPhone"
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

        let profile = try RelayProfile(
            endpoint: URL(string: "ws://localhost:8765")!,
            clientID: "hermes-ios",
            deviceID: "device-123",
            displayName: "Test Mac"
        )
        try await store.saveProfile(profile)
        try await store.saveToken("token-value", for: profile.id)

        let token = try await store.loadToken()

        XCTAssertEqual(token, "token-value")
        XCTAssertEqual(secureStore.lastReadService, "com.achappell.HermesRelayIOS.profile")
        // The account is the profile's identity, which is what lets a second
        // profile hold a second token.
        XCTAssertEqual(secureStore.lastReadAccount, profile.id.uuidString)
        XCTAssertEqual(
            secureStore.values[
                "com.achappell.HermesRelayIOS.profile/\(profile.id.uuidString)"
            ],
            Data("token-value".utf8)
        )
    }

    func testWhitespaceOnlyTokenIsRejected() async throws {
        let store = RelayConfigurationStore(
            secureStore: FakeSecureValueStore(),
            profileURL: temporaryProfileURL()
        )

        do {
            try await store.saveToken("  \n\t ", for: UUID())
            XCTFail("Whitespace-only tokens must not be stored")
        } catch let error as RelayConfigurationError {
            XCTAssertEqual(error, .emptyToken)
        }
    }

    func testEmptyStoredTokenIsRejected() async throws {
        let secureStore = FakeSecureValueStore()
        let store = RelayConfigurationStore(
            secureStore: secureStore,
            profileURL: temporaryProfileURL()
        )
        let profile = try RelayProfile(
            endpoint: URL(string: "ws://localhost:8765")!,
            clientID: "hermes-ios",
            deviceID: "device-123",
            displayName: "Test Mac"
        )
        try await store.saveProfile(profile)
        secureStore.values[
            "com.achappell.HermesRelayIOS.profile/\(profile.id.uuidString)"
        ] = Data("  ".utf8)

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
        try await store.saveToken("token-value", for: expected.id)
        try await store.deleteToken(for: expected.id)

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
            displayName: "Test iPhone"
        )

        let draft = RelayConfigurationDraft(profile: profile, hasStoredToken: true)

        XCTAssertEqual(draft.endpoint, "wss://relay.example.test/session")
        XCTAssertEqual(draft.clientID, "hermes-ios")
        XCTAssertEqual(draft.deviceID, "device-123")
        XCTAssertEqual(draft.displayName, "Test iPhone")
        XCTAssertTrue(draft.hasStoredToken)
        XCTAssertTrue(draft.token.isEmpty)
    }

    func testConfigurationDraftUsesEditableDeviceIdentityDefaults() {
        let draft = RelayConfigurationDraft(
            identity: RelayDeviceIdentity(deviceName: "Test iPhone")
        )

        #if os(iOS)
        XCTAssertEqual(draft.clientID, "hermes-ios-test-iphone")
        #elseif os(macOS)
        XCTAssertEqual(draft.clientID, "hermes-mac-test-iphone")
        #else
        XCTAssertEqual(draft.clientID, "hermes-apple-test-iphone")
        #endif
        XCTAssertEqual(draft.deviceID, "test-iphone")
        XCTAssertEqual(draft.displayName, "Test iPhone")
    }

    func testConfigurationDraftBuildsTrimmedProfileAndToken() throws {
        var draft = RelayConfigurationDraft()
        draft.endpoint = "  wss://relay.example.test/session  "
        draft.clientID = "  hermes-ios "
        draft.deviceID = " device-123 "
        draft.displayName = " Test iPhone "
        draft.token = " token-value "

        let profile = try draft.makeProfile()

        XCTAssertEqual(profile.endpoint.absoluteString, "wss://relay.example.test/session")
        XCTAssertEqual(profile.clientID, "hermes-ios")
        XCTAssertEqual(profile.deviceID, "device-123")
        XCTAssertEqual(profile.displayName, "Test iPhone")
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

    func testConfigurationDraftSurfacesEndpointAndTokenValidationBeforeSave() {
        let draft = RelayConfigurationDraft()

        XCTAssertEqual(
            draft.validationErrors[.endpoint],
            RelayConfigurationFormError.endpointRequired.errorDescription
        )
        XCTAssertEqual(
            draft.validationErrors[.token],
            RelayConfigurationFormError.tokenRequired.errorDescription
        )
    }

    func testConfigurationDraftKeepsStoredTokenOptionalAndValidatesIdentityFields() {
        var draft = RelayConfigurationDraft(hasStoredToken: true)
        draft.endpoint = "wss://relay.example.test/session"
        draft.clientID = ""
        draft.deviceID = ""
        draft.displayName = ""

        XCTAssertNil(draft.validationErrors[.token])
        XCTAssertEqual(
            draft.validationErrors[.clientID],
            RelayProfileError.emptyClientID.errorDescription
        )
        XCTAssertNil(draft.validationErrors[.deviceID])
        XCTAssertNil(draft.validationErrors[.displayName])

        draft.clientID = "client"
        XCTAssertEqual(
            draft.validationErrors[.deviceID],
            RelayProfileError.emptyDeviceID.errorDescription
        )

        draft.deviceID = "device"
        XCTAssertEqual(
            draft.validationErrors[.displayName],
            RelayProfileError.emptyDisplayName.errorDescription
        )
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

    func testProfileKeepsItsIdentityAcrossACodableRoundTrip() throws {
        let id = UUID()
        let profile = try RelayProfile(
            id: id,
            endpoint: URL(string: "wss://relay.example/socket")!,
            clientID: "client",
            deviceID: "device",
            displayName: "Relay"
        )

        let decoded = try JSONDecoder().decode(
            RelayProfile.self,
            from: JSONEncoder().encode(profile)
        )

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded, profile)
    }

    // A profile written before this change has no id field. Decoding must
    // succeed and mint one rather than throwing and stranding the user's
    // configuration.
    func testProfileWithoutAnIdDecodesWithAGeneratedIdentity() throws {
        let legacy = """
        {"endpoint":"wss://relay.example/socket","clientID":"client",\
        "deviceID":"device","displayName":"Relay"}
        """

        let decoded = try JSONDecoder().decode(
            RelayProfile.self,
            from: Data(legacy.utf8)
        )
        let second = try JSONDecoder().decode(
            RelayProfile.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(decoded.displayName, "Relay")
        // Two decodes of the same id-less JSON must mint distinct identities,
        // which proves one was generated rather than defaulted to a constant.
        XCTAssertNotEqual(decoded.id, second.id)
    }

    func testCollectionUpsertReplacesByIdentityRatherThanAppending() throws {
        let id = UUID()
        let original = try RelayProfile(
            id: id, endpoint: URL(string: "wss://one.example/s")!,
            clientID: "c", deviceID: "d", displayName: "One"
        )
        let renamed = try RelayProfile(
            id: id, endpoint: URL(string: "wss://one.example/s")!,
            clientID: "c", deviceID: "d", displayName: "Renamed"
        )
        var collection = RelayProfileCollection(profiles: [original], selectedID: id)

        collection.upsert(renamed)

        XCTAssertEqual(collection.profiles.count, 1)
        XCTAssertEqual(collection.profiles.first?.displayName, "Renamed")
        XCTAssertEqual(collection.selectedID, id)
    }

    // Deleting the active profile must not silently connect the user to a
    // different relay than the one they were using.
    func testRemovingTheSelectedProfileClearsTheSelection() throws {
        let first = try RelayProfile(
            endpoint: URL(string: "wss://one.example/s")!,
            clientID: "c", deviceID: "d", displayName: "One"
        )
        let second = try RelayProfile(
            endpoint: URL(string: "wss://two.example/s")!,
            clientID: "c", deviceID: "d", displayName: "Two"
        )
        var collection = RelayProfileCollection(
            profiles: [first, second], selectedID: first.id
        )

        collection.remove(id: first.id)

        XCTAssertEqual(collection.profiles.map(\.id), [second.id])
        XCTAssertNil(collection.selectedID)
        XCTAssertNil(collection.selectedProfile)
    }

    func testSelectedProfileResolvesTheSelectedIdentity() throws {
        let profile = try RelayProfile(
            endpoint: URL(string: "wss://one.example/s")!,
            clientID: "c", deviceID: "d", displayName: "One"
        )
        let collection = RelayProfileCollection(
            profiles: [profile], selectedID: profile.id
        )

        XCTAssertEqual(collection.selectedProfile, profile)
    }

    func testSavingTwoProfilesKeepsTheirTokensSeparate() async throws {
        let store = RelayConfigurationStore(
            secureStore: FakeSecureValueStore(), profileURL: makeTemporaryProfileURL()
        )
        let first = try RelayProfile(
            endpoint: URL(string: "wss://one.example/s")!,
            clientID: "c", deviceID: "d", displayName: "One"
        )
        let second = try RelayProfile(
            endpoint: URL(string: "wss://two.example/s")!,
            clientID: "c", deviceID: "d", displayName: "Two"
        )

        try await store.saveProfile(first)
        try await store.saveToken("token-one", for: first.id)
        try await store.saveProfile(second)
        try await store.saveToken("token-two", for: second.id)

        let loadedFirst = try await store.loadToken(for: first.id)
        let loadedSecond = try await store.loadToken(for: second.id)
        XCTAssertEqual(loadedFirst, "token-one")
        XCTAssertEqual(loadedSecond, "token-two")
    }

    func testDeletingAProfileRemovesItsSecret() async throws {
        let secureStore = FakeSecureValueStore()
        let store = RelayConfigurationStore(
            secureStore: secureStore, profileURL: makeTemporaryProfileURL()
        )
        let profile = try RelayProfile(
            endpoint: URL(string: "wss://one.example/s")!,
            clientID: "c", deviceID: "d", displayName: "One"
        )
        try await store.saveProfile(profile)
        try await store.saveToken("token-one", for: profile.id)

        try await store.deleteProfile(id: profile.id)

        let collection = try await store.loadCollection()
        XCTAssertTrue(collection.profiles.isEmpty)
        let orphaned = try await store.loadToken(for: profile.id)
        XCTAssertNil(orphaned)
        XCTAssertFalse(
            secureStore.values.keys.contains { $0.hasSuffix(profile.id.uuidString) }
        )
    }

    func testPersistedCollectionNeverContainsAToken() async throws {
        let url = makeTemporaryProfileURL()
        let store = RelayConfigurationStore(
            secureStore: FakeSecureValueStore(), profileURL: url
        )
        let profile = try RelayProfile(
            endpoint: URL(string: "wss://one.example/s")!,
            clientID: "c", deviceID: "d", displayName: "One"
        )

        try await store.saveProfile(profile)
        try await store.saveToken("super-secret-token", for: profile.id)

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(written.contains("super-secret-token"))
    }

    private func makeTemporaryProfileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesRelayIOS-Profiles-\(UUID().uuidString)")
            .appendingPathComponent("profiles.json")
    }

    func testLegacyProfileAndTokenMigrateIntoTheCollection() async throws {
        let url = makeTemporaryProfileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let legacy = """
        {"endpoint":"wss://legacy.example/socket","clientID":"client",\
        "deviceID":"device","displayName":"Legacy"}
        """
        try Data(legacy.utf8).write(to: url)
        let secureStore = FakeSecureValueStore()
        secureStore.values[
            "\(RelayConfigurationStore.keychainService)/\(RelayConfigurationStore.tokenAccount)"
        ] = Data("legacy-token".utf8)
        let store = RelayConfigurationStore(secureStore: secureStore, profileURL: url)

        let collection = try await store.loadCollection()

        let migrated = try XCTUnwrap(collection.profiles.first)
        XCTAssertEqual(collection.profiles.count, 1)
        XCTAssertEqual(migrated.displayName, "Legacy")
        XCTAssertEqual(collection.selectedID, migrated.id)
        let token = try await store.loadToken(for: migrated.id)
        XCTAssertEqual(token, "legacy-token")
    }

    // The ordering test with teeth: if writing the new account fails, the
    // legacy secret must still be there to retry from. Deleting before
    // copying would pass a "delete failed" assertion while silently losing
    // the token, so the failure injected here is the write.
    func testMigrationKeepsTheLegacySecretWhenTheCopyFails() async throws {
        let url = makeTemporaryProfileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let legacy = """
        {"endpoint":"wss://legacy.example/socket","clientID":"client",\
        "deviceID":"device","displayName":"Legacy"}
        """
        try Data(legacy.utf8).write(to: url)
        let secureStore = FakeSecureValueStore()
        let legacyKey =
            "\(RelayConfigurationStore.keychainService)/\(RelayConfigurationStore.tokenAccount)"
        secureStore.values[legacyKey] = Data("legacy-token".utf8)
        secureStore.failWrites = true
        let store = RelayConfigurationStore(secureStore: secureStore, profileURL: url)

        do {
            _ = try await store.loadCollection()
            XCTFail("A failed copy must not report a successful migration")
        } catch {
            // Expected: the migration could not complete.
        }

        XCTAssertEqual(secureStore.values[legacyKey], Data("legacy-token".utf8))
    }

    func testMigrationIsIdempotent() async throws {
        let url = makeTemporaryProfileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let legacy = """
        {"endpoint":"wss://legacy.example/socket","clientID":"client",\
        "deviceID":"device","displayName":"Legacy"}
        """
        try Data(legacy.utf8).write(to: url)
        let secureStore = FakeSecureValueStore()
        secureStore.values[
            "\(RelayConfigurationStore.keychainService)/\(RelayConfigurationStore.tokenAccount)"
        ] = Data("legacy-token".utf8)
        let store = RelayConfigurationStore(secureStore: secureStore, profileURL: url)

        let first = try await store.loadCollection()
        let second = try await store.loadCollection()

        XCTAssertEqual(first.profiles.map(\.id), second.profiles.map(\.id))
        XCTAssertEqual(second.profiles.count, 1)
    }

    @MainActor
    func testListModelSelectsAndDeletesThroughTheStore() async throws {
        let store = RelayConfigurationStore(
            secureStore: FakeSecureValueStore(), profileURL: makeTemporaryProfileURL()
        )
        let first = try RelayProfile(
            endpoint: URL(string: "wss://one.example/s")!,
            clientID: "c", deviceID: "d", displayName: "One"
        )
        let second = try RelayProfile(
            endpoint: URL(string: "wss://two.example/s")!,
            clientID: "c", deviceID: "d", displayName: "Two"
        )
        try await store.saveProfile(first)
        try await store.saveProfile(second)
        let model = RelayProfileListModel(configurationStore: store)

        await model.load()
        await model.select(id: second.id)
        XCTAssertEqual(model.collection.selectedID, second.id)

        await model.delete(id: second.id)
        XCTAssertEqual(model.collection.profiles.map(\.id), [first.id])
        XCTAssertNil(model.collection.selectedID)
    }

    @MainActor
    func testDeletingAProfileRemovesItsConversationFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesRelayIOS-Delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RelayConfigurationStore(
            secureStore: FakeSecureValueStore(),
            profileURL: directory.appendingPathComponent("profiles.json")
        )
        let profile = try RelayProfile(
            endpoint: URL(string: "wss://one.example/s")!,
            clientID: "c", deviceID: "d", displayName: "One"
        )
        try await store.saveProfile(profile)
        let conversationURL = ConversationPersistenceFile.url(in: directory, for: profile.id)
        try await JSONConversationPersistence(fileURL: conversationURL).save(
            PersistedConversation(
                messages: [TranscriptMessage(role: .user, text: "private")],
                draft: ""
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: conversationURL.path))

        let model = RelayProfileListModel(
            configurationStore: store, conversationDirectory: directory
        )
        await model.load()
        await model.delete(id: profile.id)

        // Messages must not outlive the profile they belong to.
        XCTAssertFalse(FileManager.default.fileExists(atPath: conversationURL.path))
    }
}

private final class FakeSecureValueStore: SecureValueStore, @unchecked Sendable {
    var values: [String: Data] = [:]
    var failDeletes = false
    var failWrites = false
    var lastReadService: String?
    var lastReadAccount: String?

    func read(service: String, account: String) throws -> Data? {
        lastReadService = service
        lastReadAccount = account
        return values["\(service)/\(account)"]
    }

    func write(_ value: Data, service: String, account: String) throws {
        if failWrites {
            throw KeychainError.operationFailed(status: -1, name: "write")
        }
        values["\(service)/\(account)"] = value
    }

    func delete(service: String, account: String) throws {
        if failDeletes {
            throw KeychainError.operationFailed(status: -1, name: "delete")
        }
        values.removeValue(forKey: "\(service)/\(account)")
    }

}
