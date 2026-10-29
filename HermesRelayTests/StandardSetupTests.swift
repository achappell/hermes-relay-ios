import Foundation
import XCTest
@testable import HermesRelayIOS

@MainActor
final class StandardSetupTests: XCTestCase {
    func testNewSetupNormalizesDefaultAndUsesOnlyStandardCredential() async throws {
        let secure = SetupSecureStore()
        let store = makeStore(secure)
        let model = StandardSetupModel(store: store, checkConnection: { profile, token in
            XCTAssertEqual(profile.endpoint.absoluteString, "wss://hermes.example/api/ws")
            XCTAssertEqual(profile.standardProfile, "default")
            XCTAssertEqual(token, "standard-secret")
        })
        model.draft.endpoint = "wss://hermes.example"
        model.draft.token = "standard-secret"
        model.draft.targetProfile = "  "

        let saved = await model.save()
        XCTAssertTrue(saved)
        let loadedProfile = try await store.loadProfile()
        let profile = try XCTUnwrap(loadedProfile)
        XCTAssertEqual(profile.standardProfile, "default")
        XCTAssertEqual(profile.clientID, "")
        XCTAssertEqual(profile.deviceID, "")
        let token = try await store.loadStandardToken(for: profile.id)
        XCTAssertEqual(token, "standard-secret")
        XCTAssertFalse(secure.readServices.contains(RelayConfigurationStore.keychainService))
        XCTAssertFalse(secure.writeServices.contains(RelayConfigurationStore.keychainService))
        XCTAssertEqual(model.draft.token, "")
    }

    func testEndpointChangeRequiresNewTokenBeforeProbeOrSave() async throws {
        let store = makeStore()
        let original = try await seed(store)
        let model = StandardSetupModel(profile: original, store: store, checkConnection: { _, _ in
            XCTFail("A token from the old endpoint must never reach the probe")
        })
        model.draft.endpoint = "wss://different.example/api/ws"

        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(model.errorMessage, StandardSetupError.newEndpointNeedsToken.localizedDescription)
        let collection = try await store.loadCollection()
        XCTAssertEqual(collection.profiles, [original])
        XCTAssertEqual(collection.selectedID, original.id)
    }

    func testTargetChangeCreatesNewIdentityAndRetainsOriginalCredentialAndHistory() async throws {
        let store = makeStore()
        let original = try await seed(store)
        let model = StandardSetupModel(profile: original, store: store, checkConnection: { profile, token in
            XCTAssertEqual(profile.standardProfile, "work")
            XCTAssertEqual(token, "original-secret")
        })
        model.draft.targetProfile = "work"

        let saved = await model.save()
        XCTAssertTrue(saved)
        let collection = try await store.loadCollection()
        let selected = try XCTUnwrap(collection.selectedProfile)
        XCTAssertNotEqual(selected.id, original.id)
        XCTAssertEqual(collection.profiles.count, 2)
        XCTAssertTrue(collection.profiles.contains(original))
        let oldToken = try await store.loadStandardToken(for: original.id)
        let newToken = try await store.loadStandardToken(for: selected.id)
        XCTAssertEqual(oldToken, "original-secret")
        XCTAssertEqual(newToken, oldToken)
        let directory = FileManager.default.temporaryDirectory
        XCTAssertNotEqual(
            ConversationPersistenceFile.url(in: directory, for: original),
            ConversationPersistenceFile.url(in: directory, for: selected)
        )
    }

    func testTokenReplacementCreatesNewIdentityWithoutOverwritingOriginal() async throws {
        let store = makeStore()
        let original = try await seed(store)
        let model = StandardSetupModel(profile: original, store: store, checkConnection: { _, _ in })
        model.draft.token = "replacement-secret"

        let saved = await model.save()
        XCTAssertTrue(saved)
        let loadedProfile = try await store.loadProfile()
        let selected = try XCTUnwrap(loadedProfile)
        XCTAssertNotEqual(selected.id, original.id)
        let oldToken = try await store.loadStandardToken(for: original.id)
        let newToken = try await store.loadStandardToken(for: selected.id)
        XCTAssertEqual(oldToken, "original-secret")
        XCTAssertEqual(newToken, "replacement-secret")
    }

    func testUnchangedConnectionKeepsIdentity() throws {
        let original = try RelayProfile.standard(endpoint: URL(string: "wss://hermes.example/api/ws")!)
        let draft = StandardSetupDraft(profile: original)
        let connection = try draft.connection(original: original, storedToken: "secret")
        XCTAssertEqual(connection.profile, original)
    }

    func testFailedReadinessSavesNothingAndRedactsTransportErrors() async throws {
        let secure = SetupSecureStore()
        let store = makeStore(secure)
        let model = StandardSetupModel(store: store, checkConnection: { _, _ in
            throw NSError(domain: "wss://hermes.example/api/ws?token=sentinel-secret", code: 1)
        })
        model.draft.endpoint = "wss://hermes.example"
        model.draft.token = "sentinel-secret"

        let saved = await model.save()
        XCTAssertFalse(saved)
        let collection = try await store.loadCollection()
        XCTAssertTrue(collection.profiles.isEmpty)
        XCTAssertTrue(secure.writeServices.isEmpty)
        XCTAssertFalse(model.errorMessage?.contains("sentinel-secret") ?? true)
        XCTAssertFalse(model.errorMessage?.contains("wss://") ?? true)
    }

    func testBlockedConnectionCannotProbeOrSave() async throws {
        let store = makeStore()
        let model = StandardSetupModel(
            store: store,
            blockedReason: { "Leave the uncertain conversation first." },
            checkConnection: { _, _ in XCTFail("Blocked configuration cannot probe") }
        )
        model.draft.endpoint = "wss://hermes.example"
        model.draft.token = "secret"

        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(model.errorMessage, "Leave the uncertain conversation first.")
        let collection = try await store.loadCollection()
        XCTAssertTrue(collection.profiles.isEmpty)
    }

    func testGuardIsRecheckedAfterAwaitedConnectionCheck() async throws {
        let blocker = SetupBlocker()
        let store = makeStore()
        let model = StandardSetupModel(
            store: store,
            blockedReason: { blocker.reason },
            checkConnection: { _, _ in
                await MainActor.run { blocker.reason = "A turn is now active." }
            }
        )
        model.draft.endpoint = "wss://hermes.example"
        model.draft.token = "secret"

        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(model.errorMessage, "A turn is now active.")
        let collection = try await store.loadCollection()
        XCTAssertTrue(collection.profiles.isEmpty)
    }

    func testLeaseCoversReadinessCommitAndAwaitedSessionSwitchWithoutNestedSave() async throws {
        let lease = SetupLease()
        let store = makeStore()
        let model = StandardSetupModel(
            store: store,
            beginReconfiguration: {
                guard lease.begin() else { return false }
                await Task.yield()
                lease.captureStopped = true
                return true
            },
            endReconfiguration: { lease.end() },
            checkConnection: { _, _ in
                await MainActor.run {
                    XCTAssertTrue(lease.isHeld)
                    XCTAssertTrue(lease.captureStopped, "Readiness must wait for capture teardown")
                }
                await Task.yield()
                await MainActor.run { XCTAssertTrue(lease.isHeld) }
            }
        )
        let competing = StandardSetupModel(
            store: store,
            beginReconfiguration: { lease.begin() },
            endReconfiguration: { lease.end() },
            checkConnection: { _, _ in XCTFail("A nested transaction must not probe") }
        )
        model.draft.endpoint = "wss://hermes.example"
        model.draft.token = "secret"
        competing.draft.endpoint = "wss://other.example"
        competing.draft.token = "other-secret"
        var switchedProfile: RelayProfile?

        let saved = await model.save {
            XCTAssertTrue(lease.isHeld)
            switchedProfile = try? await store.loadProfile()
            let nestedSave = await competing.save()
            XCTAssertFalse(nestedSave)
            let sameModelSave = await model.save()
            XCTAssertFalse(sameModelSave)
            await Task.yield()
            XCTAssertTrue(lease.isHeld, "Do not release before the live session switch returns")
        }

        XCTAssertTrue(saved)
        XCTAssertEqual(switchedProfile?.endpoint.host, "hermes.example")
        XCTAssertFalse(lease.isHeld)
        XCTAssertEqual(lease.endCount, 1, "Rejected nested work must not end the owner's lease")
        let collection = try await store.loadCollection()
        XCTAssertEqual(collection.profiles.count, 1)
    }

    func testRejectedLeaseCannotProbeCommitOrReleaseAnotherOwner() async throws {
        let lease = SetupLease()
        XCTAssertTrue(lease.begin())
        let store = makeStore()
        let model = StandardSetupModel(
            store: store,
            beginReconfiguration: { lease.begin() },
            endReconfiguration: { lease.end() },
            checkConnection: { _, _ in XCTFail("Rejected lease cannot probe") }
        )
        model.draft.endpoint = "wss://hermes.example"
        model.draft.token = "secret"

        let saved = await model.save {
            XCTFail("Rejected lease cannot switch the session")
        }

        XCTAssertFalse(saved)
        XCTAssertTrue(lease.isHeld)
        XCTAssertEqual(lease.endCount, 0)
        XCTAssertFalse(model.isSaving)
        let collection = try await store.loadCollection()
        XCTAssertTrue(collection.profiles.isEmpty)
        lease.end()
    }

    func testReadinessFailureReleasesLeaseWithoutSessionSwitch() async throws {
        let lease = SetupLease()
        let store = makeStore()
        let model = StandardSetupModel(
            store: store,
            beginReconfiguration: { lease.begin() },
            endReconfiguration: { lease.end() },
            checkConnection: { _, _ in throw URLError(.cannotConnectToHost) }
        )
        model.draft.endpoint = "wss://hermes.example"
        model.draft.token = "secret"

        let saved = await model.save { XCTFail("Failed readiness cannot switch the session") }

        XCTAssertFalse(saved)
        XCTAssertFalse(lease.isHeld)
        XCTAssertEqual(lease.endCount, 1)
        let collection = try await store.loadCollection()
        XCTAssertTrue(collection.profiles.isEmpty)
    }

    func testCommitFailureRollsBackBeforeReleasingLease() async throws {
        let lease = SetupLease()
        let secure = SetupSecureStore()
        let store = makeStore(secure)
        let original = try await seed(store)
        secure.failWrites = true
        let model = StandardSetupModel(
            profile: original,
            store: store,
            beginReconfiguration: { lease.begin() },
            endReconfiguration: {
                XCTAssertEqual(secure.valueCount, 1)
                lease.end()
            },
            checkConnection: { _, _ in }
        )
        model.draft.targetProfile = "work"

        let saved = await model.save { XCTFail("Rolled back save cannot switch the session") }

        XCTAssertFalse(saved)
        XCTAssertFalse(lease.isHeld)
        XCTAssertEqual(lease.endCount, 1)
        let collection = try await store.loadCollection()
        XCTAssertEqual(collection.selectedProfile, original)
        XCTAssertEqual(collection.profiles, [original])
    }

    func testInvalidEndpointNeverProbes() async throws {
        for endpoint in ["ws://hermes.example/api/ws", "wss://user:secret@hermes.example/api/ws", "wss://hermes.example/api/ws?%74oken=secret", "wss://hermes.example/other"] {
            let model = StandardSetupModel(store: makeStore(), checkConnection: { _, _ in
                XCTFail("Invalid endpoints cannot be probed")
            })
            model.draft.endpoint = endpoint
            model.draft.token = "secret"
            let saved = await model.save()
            XCTAssertFalse(saved, endpoint)
        }
    }

    func testProfileWriteFailureRollsBackNewSetupCredentialAndSelection() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedParent = directory.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedParent)
        let secure = SetupSecureStore()
        let store = RelayConfigurationStore(
            secureStore: secure, profileURL: blockedParent.appendingPathComponent("profiles.json")
        )
        let model = StandardSetupModel(store: store, checkConnection: { _, _ in })
        model.draft.endpoint = "wss://hermes.example"
        model.draft.token = "new-secret"

        let saved = await model.save()

        XCTAssertFalse(saved)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(secure.isEmpty)
        XCTAssertTrue(secure.writeServices.contains(RelayConfigurationStore.standardKeychainService))
        let collection = try await store.loadCollection()
        XCTAssertTrue(collection.profiles.isEmpty)
        XCTAssertNil(collection.selectedID)
    }

    func testProfileWriteFailureDuringEditRetainsOriginalCredentialAndSelection() async throws {
        let directory = temporaryDirectory()
        let secure = SetupSecureStore()
        let store = RelayConfigurationStore(
            secureStore: secure, profileURL: directory.appendingPathComponent("profiles.json")
        )
        let original = try await seed(store)
        let model = StandardSetupModel(profile: original, store: store, checkConnection: { _, _ in })
        model.draft.targetProfile = "work"
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        let saved = await model.save()

        XCTAssertFalse(saved)
        let collection = try await store.loadCollection()
        XCTAssertEqual(collection.profiles, [original])
        XCTAssertEqual(collection.selectedID, original.id)
        let token = try await store.loadStandardToken(for: original.id)
        XCTAssertEqual(token, "original-secret")
        XCTAssertEqual(secure.valueCount, 1)
        XCTAssertEqual(secure.writeServices.count, 2)
    }

    func testFailedEndpointUpdatePreservesOriginalConnectionCredentialAndHistory() async throws {
        let secure = SetupSecureStore()
        let store = makeStore(secure)
        let original = try await seed(store)
        let directory = temporaryDirectory()
        let history = JSONConversationPersistence(fileURL: ConversationPersistenceFile.url(in: directory, for: original))
        let transcript = PersistedConversation(messages: [], draft: "Original draft", standardSessionID: "original-session")
        try await history.save(transcript)
        secure.failWrites = true
        let model = StandardSetupModel(profile: original, store: store, checkConnection: { profile, token in
            XCTAssertNotEqual(profile.id, original.id)
            XCTAssertEqual(token, "new-secret")
        })
        model.draft.endpoint = "wss://different.example/api/ws"
        model.draft.token = "new-secret"

        let saved = await model.save()

        XCTAssertFalse(saved)
        let collection = try await store.loadCollection()
        XCTAssertEqual(collection.profiles, [original])
        XCTAssertEqual(collection.selectedID, original.id)
        let token = try await store.loadStandardToken(for: original.id)
        XCTAssertEqual(token, "original-secret")
        let retained = try await history.load()
        XCTAssertEqual(retained, transcript)
        XCTAssertEqual(secure.valueCount, 1)
    }

    func testStandardDeletionPersistenceFailurePreservesHistoryAndSelection() async throws {
        let directory = temporaryDirectory()
        let profileDirectory = directory.appendingPathComponent("configuration")
        let secure = SetupSecureStore()
        let store = RelayConfigurationStore(
            secureStore: secure, profileURL: profileDirectory.appendingPathComponent("profiles.json")
        )
        let original = try await seed(store)
        let history = JSONConversationPersistence(fileURL: ConversationPersistenceFile.url(in: directory, for: original))
        let transcript = PersistedConversation(messages: [], draft: "Keep this transcript", standardSessionID: "saved-session")
        try await history.save(transcript)
        let model = RelayProfileListModel(configurationStore: store, conversationDirectory: directory)
        await model.load()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: profileDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profileDirectory.path)
        }

        let deleted = await model.delete(id: original.id)

        XCTAssertFalse(deleted)
        XCTAssertNotNil(model.errorMessage)
        let retained = try await history.load()
        XCTAssertEqual(retained, transcript)
        let collection = try await store.loadCollection()
        XCTAssertEqual(collection.profiles, [original])
        XCTAssertEqual(collection.selectedID, original.id)
    }

    func testLegacyEndpointChangeRequiresEnteredTokenAndKeepsOriginalIdentityUntouched() throws {
        let original = try RelayProfile(
            endpoint: URL(string: "wss://legacy.example/ws")!,
            clientID: "client", deviceID: "device", displayName: "My original relay"
        )
        var draft = RelayConfigurationDraft(profile: original, hasStoredToken: true)
        draft.endpoint = "wss://different.example/ws"
        XCTAssertThrowsError(try draft.legacyConnection(original: original, storedToken: "old-secret"))
        draft.token = "new-secret"

        let connection = try draft.legacyConnection(original: original, storedToken: "old-secret")

        XCTAssertNotEqual(connection.profile.id, original.id)
        XCTAssertEqual(connection.profile.displayName, original.displayName)
        XCTAssertEqual(connection.token, "new-secret")
        XCTAssertEqual(original.endpoint.absoluteString, "wss://legacy.example/ws")
    }

    func testLegacyUnchangedEndpointKeepsIdentityAndStoredToken() throws {
        let original = try RelayProfile(
            endpoint: URL(string: "wss://legacy.example/ws")!,
            clientID: "client", deviceID: "device", displayName: "My relay"
        )
        let draft = RelayConfigurationDraft(profile: original, hasStoredToken: true)

        let connection = try draft.legacyConnection(original: original, storedToken: "old-secret")

        XCTAssertEqual(connection.profile, original)
        XCTAssertEqual(connection.token, "old-secret")
    }

    func testLegacyEndpointSaveRetainsOriginalCredentialAndHistory() async throws {
        let secure = SetupSecureStore()
        let store = makeStore(secure)
        let original = try RelayProfile(
            endpoint: URL(string: "wss://legacy.example/ws")!,
            clientID: "client", deviceID: "device", displayName: "Original relay"
        )
        try await store.saveLegacyConnection(original, token: "old-secret")
        let directory = temporaryDirectory()
        let history = JSONConversationPersistence(fileURL: ConversationPersistenceFile.url(in: directory, for: original))
        let transcript = PersistedConversation(messages: [], draft: "Original history")
        try await history.save(transcript)
        var draft = RelayConfigurationDraft(profile: original, hasStoredToken: true)
        draft.endpoint = "wss://different.example/ws"
        draft.token = "new-secret"
        let connection = try draft.legacyConnection(original: original, storedToken: "old-secret")

        try await store.saveLegacyConnection(connection.profile, token: connection.token)

        let collection = try await store.loadCollection()
        XCTAssertTrue(collection.profiles.contains(original))
        XCTAssertEqual(collection.profiles.count, 2)
        XCTAssertEqual(collection.selectedID, connection.profile.id)
        let oldToken = try await store.loadToken(for: original.id)
        let newToken = try await store.loadToken(for: connection.profile.id)
        XCTAssertEqual(oldToken, "old-secret")
        XCTAssertEqual(newToken, "new-secret")
        let retained = try await history.load()
        XCTAssertEqual(retained, transcript)
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func seed(_ store: RelayConfigurationStore) async throws -> RelayProfile {
        let profile = try RelayProfile.standard(endpoint: URL(string: "wss://hermes.example/api/ws")!)
        try await store.saveProfile(profile)
        try await store.saveStandardToken("original-secret", for: profile.id)
        return profile
    }

    private func makeStore(_ secure: SetupSecureStore = SetupSecureStore()) -> RelayConfigurationStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return RelayConfigurationStore(secureStore: secure, profileURL: directory.appendingPathComponent("profiles.json"))
    }
}

@MainActor
private final class SetupBlocker {
    var reason: String?
}

@MainActor
private final class SetupLease {
    private(set) var isHeld = false
    var captureStopped = false
    private(set) var endCount = 0

    func begin() -> Bool {
        guard !isHeld else { return false }
        isHeld = true
        return true
    }

    func end() {
        XCTAssertTrue(isHeld)
        isHeld = false
        endCount += 1
    }
}

private final class SetupSecureStore: SecureValueStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    var failWrites = false
    var isEmpty: Bool { values.isEmpty }
    var valueCount: Int { values.count }
    private(set) var readServices: [String] = []
    private(set) var writeServices: [String] = []

    func read(service: String, account: String) throws -> Data? {
        readServices.append(service)
        return values["\(service)/\(account)"]
    }

    func write(_ value: Data, service: String, account: String) throws {
        if failWrites {
            throw KeychainError.operationFailed(status: -1, name: "write")
        }
        writeServices.append(service)
        values["\(service)/\(account)"] = value
    }

    func delete(service: String, account: String) throws {
        values.removeValue(forKey: "\(service)/\(account)")
    }
}
