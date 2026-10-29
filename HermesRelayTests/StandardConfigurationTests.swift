import Foundation
import XCTest
@testable import HermesRelayIOS

final class StandardConfigurationTests: XCTestCase {
    func testStandardCanonicalizesEndpointAndDefaultTargetWithoutDeviceIdentity() throws {
        let profile = try RelayProfile.standard(endpoint: URL(string: "wss://AGENT.example.test")!, targetProfile: " \n ")
        XCTAssertEqual(profile.endpoint.absoluteString, "wss://agent.example.test/api/ws")
        XCTAssertEqual(profile.standardProfile, "default")
        XCTAssertTrue(profile.clientID.isEmpty)
        XCTAssertTrue(profile.deviceID.isEmpty)
        XCTAssertEqual(RelayProfileCollection(profiles: [profile]).transportMode(for: profile.id), .standard)
    }

    func testStandardRejectsCleartextCredentialsQueriesFragmentsAndOtherPaths() {
        for endpoint in [
            "ws://agent.example.test/api/ws", "wss://user:secret@agent.example.test/api/ws",
            "wss://agent.example.test/api/ws?token=secret", "wss://agent.example.test/api/ws?%74oken=secret",
            "wss://agent.example.test/api/ws?access_token=secret", "wss://agent.example.test/api/ws?key=secret",
            "wss://agent.example.test/api/ws?profile=other", "wss://agent.example.test/proxy/api/ws",
            "wss://agent.example.test/api/ws#secret"
        ] {
            XCTAssertThrowsError(try RelayProfile.standard(endpoint: URL(string: endpoint)!))
        }
    }

    func testExistingProfileDecodesAsLegacyAndSurvivesDirectCollectionRoundTrip() throws {
        let legacy = try RelayProfile(endpoint: URL(string: "ws://localhost:8765")!, clientID: "ios", deviceID: "phone", displayName: "Existing")
        let direct = try RelayProfile.standard(endpoint: URL(string: "wss://agent.example.test/api/ws")!)
        let oldData = try JSONEncoder().encode(legacy)
        let decodedLegacy = try JSONDecoder().decode(RelayProfile.self, from: oldData)
        XCTAssertNil(decodedLegacy.standardProfile)
        let collection = RelayProfileCollection(profiles: [legacy, direct], selectedID: direct.id)
        let data = try JSONEncoder().encode(collection)
        let restored = try JSONDecoder().decode(RelayProfileCollection.self, from: data)
        XCTAssertEqual(restored, collection)
        XCTAssertEqual(restored.transportMode(for: legacy.id), .legacy)
        XCTAssertEqual(restored.transportMode(for: direct.id), .standard)

        // Retained pre-Standard collection decoder shape: old builds ignore
        // unknown keys, retain all connections they understand, and cannot
        // accidentally connect the direct endpoint through the fork adapter.
        let older = try JSONDecoder().decode(PreStandardCollection.self, from: data)
        XCTAssertEqual(older.profiles, [legacy])
        XCTAssertNil(older.selectedProfile)
    }

    func testStandardBindingDoesNotExposeForkSessionID() {
        let metadata = SessionMetadata(standardSessionID: "runtime", storedSessionID: "durable")
        XCTAssertNil(metadata.sessionID)
        XCTAssertEqual(metadata.binding, .standard(sessionID: "runtime", storedSessionID: "durable"))
        let turn = HermesTurnBinding(profileID: UUID(), standardSessionID: "runtime", storedSessionID: "durable")
        XCTAssertNil(turn.sessionID)
        XCTAssertNil(turn.homeConversation)
    }

    func testDirectCredentialsNeverReadOrDeleteOtherNamespaces() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secure = StandardSecureStore()
        let store = RelayConfigurationStore(secureStore: secure, profileURL: directory.appendingPathComponent("profiles.json"))
        let profile = try RelayProfile.standard(endpoint: URL(string: "wss://agent.example.test")!)
        let account = profile.id.uuidString
        let otherSlots = [
            (RelayConfigurationStore.keychainService, account),
            (HomeCredentialKeychain.service, HomeCredentialKeychain.account(for: profile.id)),
            (HomeAdminCredentialKeychain.service, HomeAdminCredentialKeychain.account(for: profile.id))
        ]
        for (service, otherAccount) in otherSlots {
            try secure.write(Data("other-secret".utf8), service: service, account: otherAccount)
        }
        try await store.saveProfile(profile)
        let missing = try await store.loadStandardToken(for: profile.id)
        XCTAssertNil(missing)
        XCTAssertEqual(secure.readServices, [RelayConfigurationStore.standardKeychainService])
        try await store.saveStandardToken("direct-secret", for: profile.id)
        let token = try await store.loadStandardToken(for: profile.id)
        XCTAssertEqual(token, "direct-secret")
        let data = try Data(contentsOf: directory.appendingPathComponent("profiles.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
        try await store.deleteProfile(id: profile.id)
        XCTAssertNil(try secure.read(service: RelayConfigurationStore.standardKeychainService, account: account))
        for (service, otherAccount) in otherSlots {
            XCTAssertEqual(try secure.read(service: service, account: otherAccount), Data("other-secret".utf8))
        }
    }

    func testStandardIdentityCannotBeRetargetedInPlace() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RelayConfigurationStore(secureStore: StandardSecureStore(), profileURL: directory.appendingPathComponent("profiles.json"))
        let original = try RelayProfile.standard(endpoint: URL(string: "wss://first.example.test")!)
        try await store.saveProfile(original)
        let changed = try RelayProfile.standard(endpoint: URL(string: "wss://second.example.test")!, id: original.id)
        do {
            try await store.saveProfile(changed)
            XCTFail("A different direct connection must get a different local identity")
        } catch {
            XCTAssertEqual(error as? RelayConfigurationError, .invalidProfile)
        }
        let current = try await store.loadProfile()
        XCTAssertEqual(current, original)
    }

    func testExistingLegacyEndpointChangeCannotKeepBearerForAnotherHost() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RelayConfigurationStore(secureStore: StandardSecureStore(), profileURL: directory.appendingPathComponent("profiles.json"))
        let original = try RelayProfile(endpoint: URL(string: "wss://first.example.test")!, clientID: "ios", deviceID: "phone", displayName: "Legacy")
        try await store.saveProfile(original)
        try await store.saveToken("first-host-secret", for: original.id)
        let changed = try RelayProfile(id: original.id, endpoint: URL(string: "wss://second.example.test")!, clientID: "ios", deviceID: "phone", displayName: "Legacy")
        do {
            try await store.saveProfile(changed)
            XCTFail("Retargeting an existing connection must be rejected")
        } catch {
            XCTAssertEqual(error as? RelayConfigurationError, .invalidProfile)
        }
        let token = try await store.loadToken(for: original.id)
        XCTAssertEqual(token, "first-host-secret")
        let saved = try await store.loadProfile()
        XCTAssertEqual(saved, original)
        let replacement = try RelayProfile(endpoint: changed.endpoint, clientID: "ios", deviceID: "phone", displayName: "Legacy")
        try await store.saveLegacyConnection(replacement, token: "second-host-secret")
        let previousToken = try await store.loadToken(for: original.id)
        let replacementToken = try await store.loadToken(for: replacement.id)
        XCTAssertEqual(previousToken, "first-host-secret")
        XCTAssertEqual(replacementToken, "second-host-secret")
        let collection = try await store.loadCollection()
        XCTAssertEqual(collection.profiles, [original, replacement])
        XCTAssertEqual(collection.selectedID, replacement.id)
    }

    func testFailedConnectionPersistenceRemovesOnlyNewCredentialAccount() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blocker)
        let secure = StandardSecureStore()
        let store = RelayConfigurationStore(secureStore: secure, profileURL: blocker.appendingPathComponent("profiles.json"))
        let direct = try RelayProfile.standard(endpoint: URL(string: "wss://direct.example.test")!)
        let legacy = try RelayProfile(endpoint: URL(string: "wss://legacy.example.test")!, clientID: "ios", deviceID: "phone", displayName: "Legacy")
        let preservedID = UUID()
        try await store.saveStandardToken("preserved-direct", for: preservedID)
        try await store.saveToken("preserved-legacy", for: preservedID)
        do {
            try await store.saveStandardConnection(direct, token: "new-direct")
            XCTFail("An unwritable collection must not be reported as saved")
        } catch {}
        do {
            try await store.saveLegacyConnection(legacy, token: "new-legacy")
            XCTFail("An unwritable collection must not be reported as saved")
        } catch {}
        let orphanDirect = try await store.loadStandardToken(for: direct.id)
        let orphanLegacy = try await store.loadToken(for: legacy.id)
        let preservedDirect = try await store.loadStandardToken(for: preservedID)
        let preservedLegacy = try await store.loadToken(for: preservedID)
        XCTAssertNil(orphanDirect)
        XCTAssertNil(orphanLegacy)
        XCTAssertEqual(preservedDirect, "preserved-direct")
        XCTAssertEqual(preservedLegacy, "preserved-legacy")
    }

    func testStandardHistoryRemainsPrivateToModeEndpointTargetAndLocalIdentity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try RelayProfile.standard(endpoint: URL(string: "wss://first.example.test")!)
        let endpointChanged = try RelayProfile.standard(endpoint: URL(string: "wss://second.example.test")!, id: original.id)
        let targetChanged = try RelayProfile.standard(endpoint: original.endpoint, targetProfile: "work", id: original.id)
        let anotherLocalProfile = try RelayProfile.standard(endpoint: original.endpoint)
        let originalURL = ConversationPersistenceFile.url(in: directory, for: original)
        let persistence = JSONConversationPersistence(fileURL: originalURL)
        let history = PersistedConversation(messages: [TranscriptMessage(role: .user, text: "Uncertain original prompt")], draft: "private draft", unconfirmedTurnText: "Uncertain original prompt", standardSessionID: "durable-original")
        try await persistence.save(history)
        for profile in [endpointChanged, targetChanged, anotherLocalProfile] {
            let url = ConversationPersistenceFile.url(in: directory, for: profile)
            XCTAssertNotEqual(url, originalURL)
            let isolated = try await JSONConversationPersistence(fileURL: url).load()
            XCTAssertTrue(isolated.messages.isEmpty)
            XCTAssertNil(isolated.unconfirmedTurnText)
            XCTAssertNil(isolated.standardSessionID)
        }
        let legacyURL = ConversationPersistenceFile.url(in: directory, for: original.id)
        XCTAssertNotEqual(legacyURL, originalURL)
        let recovered = try await persistence.load()
        XCTAssertEqual(recovered, history)
    }

    func testDeletingOneDirectProfileRemovesAllItsHistoryButKeepsOtherConnections() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try RelayProfile.standard(endpoint: URL(string: "wss://first.example.test")!)
        let oldTarget = try RelayProfile.standard(endpoint: first.endpoint, targetProfile: "old", id: first.id)
        let second = try RelayProfile.standard(endpoint: first.endpoint)
        let files = [first, oldTarget, second].map { ConversationPersistenceFile.url(in: directory, for: $0) }
        for file in files { try await JSONConversationPersistence(fileURL: file).save(PersistedConversation(messages: [], draft: "kept")) }
        try ConversationPersistenceFile.delete(in: directory, for: first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[2].path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("StandardConfigurationTests-\(UUID().uuidString)")
    }
}

private struct PreStandardCollection: Decodable {
    let schemaVersion: Int
    let profiles: [RelayProfile]
    let selectedID: UUID?
    let homeMigrations: [UUID: HomeMigrationJournal]?
    var selectedProfile: RelayProfile? { profiles.first { $0.id == selectedID } }
}

private final class StandardSecureStore: SecureValueStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private(set) var readServices: [String] = []
    func read(service: String, account: String) throws -> Data? {
        readServices.append(service)
        return values["\(service)/\(account)"]
    }
    func write(_ value: Data, service: String, account: String) throws { values["\(service)/\(account)"] = value }
    func delete(service: String, account: String) throws { values.removeValue(forKey: "\(service)/\(account)") }
}
