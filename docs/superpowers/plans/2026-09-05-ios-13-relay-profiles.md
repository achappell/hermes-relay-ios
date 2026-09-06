# IOS-13 Saved Relay Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user save several Hermes relay profiles and switch the active connection without re-entering credentials.

**Architecture:** `RelayProfile` gains a stable `UUID`. A new `RelayProfileCollection` (profiles + selectedID + schemaVersion) replaces the single-profile JSON file, and Keychain tokens move from one fixed account to one account per profile UUID. `RelayConfigurationStore` grows collection and per-profile token methods while keeping `loadProfile()`/`loadToken()` as "the selected one" accessors, so `ConversationStore` and auto-connect need no structural change.

**Tech Stack:** Swift 6.3, SwiftUI, XCTest, Xcode 26.6, iOS 26 / macOS 26 deployment targets.

**Spec:** `docs/superpowers/specs/2026-09-05-ios-13-relay-profiles-design.md`

## Global Constraints

- Swift 6.3 with Xcode 26.6; iOS 26 and macOS 26 deployment targets. Both platforms must build.
- Never log, render, or place a bearer token in a test fixture, screenshot, or persisted JSON.
- Keychain service stays `com.achappell.HermesRelayIOS.profile`. Only the account changes.
- `RelayProfile` keeps its throwing validating initializer; do not bypass validation.
- Every new file must be added to `HermesRelayIOS.xcodeproj/project.pbxproj` by hand — the project has no file-system-synchronized groups.
- After adding a file to the project, run `xcodebuild clean` before `xcodebuild test`. A stale `.swiftmodule` otherwise reports `cannot find X in scope` for a file that is present and correct.
- Run both: `xcodebuild test -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` and `xcodebuild build -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=macOS,arch=arm64'`.

---

### Task 1: Give RelayProfile a stable identity

**Files:**
- Modify: `HermesRelayIOS/Models/RelayProfile.swift`
- Test: `HermesRelayIOSTests/RelayConfigurationTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `RelayProfile.id: UUID`; initializer `init(id: UUID = UUID(), endpoint: URL, clientID: String, deviceID: String, displayName: String) throws`. Decoding a JSON object with no `id` yields a freshly generated one.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `xcodebuild test -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:HermesRelayIOSTests/RelayConfigurationTests`
Expected: FAIL — `extra argument 'id' in call`.

- [ ] **Step 3: Add the identity**

In `RelayProfile`, add the stored property and extend the initializer:

```swift
struct RelayProfile: Codable, Equatable, Sendable {
    let id: UUID
    let endpoint: URL
    let clientID: String
    let deviceID: String
    let displayName: String

    init(
        id: UUID = UUID(),
        endpoint: URL,
        clientID: String,
        deviceID: String,
        displayName: String
    ) throws {
        self.id = id
        // ...existing validation, unchanged...
    }
}
```

Add a decoder that tolerates a missing `id`, because files written before this
change do not have one:

```swift
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            endpoint: container.decode(URL.self, forKey: .endpoint),
            clientID: container.decode(String.self, forKey: .clientID),
            deviceID: container.decode(String.self, forKey: .deviceID),
            displayName: container.decode(String.self, forKey: .displayName)
        )
    }
```

Note the `try self.init(...)` — routing through the validating initializer is
deliberate, so a hand-edited file cannot introduce an invalid profile.

- [ ] **Step 4: Run the tests and watch them pass**

Run the same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add HermesRelayIOS/Models/RelayProfile.swift HermesRelayIOSTests/RelayConfigurationTests.swift
git commit -m "feat: give RelayProfile a stable identity"
```

---

### Task 2: The profile collection model

**Files:**
- Create: `HermesRelayIOS/Models/RelayProfileCollection.swift`
- Modify: `HermesRelayIOS.xcodeproj/project.pbxproj`
- Test: `HermesRelayIOSTests/RelayConfigurationTests.swift`

**Interfaces:**
- Consumes: `RelayProfile.id` from Task 1.
- Produces: `RelayProfileCollection` with `schemaVersion: Int`, `profiles: [RelayProfile]`, `selectedID: UUID?`; `var selectedProfile: RelayProfile?`; `mutating func upsert(_ profile: RelayProfile)`; `mutating func remove(id: UUID)`; `static let currentSchemaVersion = 1`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run the tests and watch them fail**

Expected: FAIL — `cannot find 'RelayProfileCollection' in scope`.

- [ ] **Step 3: Create the model**

`HermesRelayIOS/Models/RelayProfileCollection.swift`:

```swift
import Foundation

/// Every saved relay and which one is active.
///
/// `schemaVersion` is present from the first release so a later change is a
/// cheap migration rather than guesswork about which shape is on disk.
struct RelayProfileCollection: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var profiles: [RelayProfile]
    var selectedID: UUID?

    init(
        schemaVersion: Int = RelayProfileCollection.currentSchemaVersion,
        profiles: [RelayProfile] = [],
        selectedID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.selectedID = selectedID
    }

    var selectedProfile: RelayProfile? {
        guard let selectedID else { return nil }
        return profiles.first { $0.id == selectedID }
    }

    mutating func upsert(_ profile: RelayProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    /// Removing the active profile clears the selection. Promoting a
    /// neighbour would silently retarget the user's next Connect.
    mutating func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = nil
        }
    }
}
```

- [ ] **Step 4: Add the file to the Xcode project**

The project has no synchronized groups, so the file needs `PBXBuildFile`,
`PBXFileReference`, group-children and Sources-phase entries. Follow the
existing `RelayProfile.swift` entries as the template — copy each of its four
lines, change the identifier and filename. Use unused identifiers in the
`A1000000000000000000____` range.

- [ ] **Step 5: Clean, then run the tests and watch them pass**

```bash
xcodebuild clean -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS
xcodebuild test -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
Expected: PASS. The clean matters — without it a newly added file reports as
missing from scope.

- [ ] **Step 6: Commit**

```bash
git add HermesRelayIOS/Models/RelayProfileCollection.swift HermesRelayIOS.xcodeproj/project.pbxproj HermesRelayIOSTests/RelayConfigurationTests.swift
git commit -m "feat: add the relay profile collection model"
```

---

### Task 3: Per-profile storage in RelayConfigurationStore

**Files:**
- Modify: `HermesRelayIOS/Services/RelayConfigurationStore.swift`
- Test: `HermesRelayIOSTests/RelayConfigurationTests.swift`

**Interfaces:**
- Consumes: `RelayProfileCollection` from Task 2.
- Produces: on `RelayConfigurationStore` — `func loadCollection() async throws -> RelayProfileCollection`, `func saveProfile(_ profile: RelayProfile) async throws`, `func deleteProfile(id: UUID) async throws`, `func selectProfile(id: UUID) async throws`, `func loadToken(for id: UUID) async throws -> String?`, `func saveToken(_ token: String, for id: UUID) async throws`, and `static func tokenAccount(for id: UUID) -> String` returning `id.uuidString`.

- [ ] **Step 1: Write the failing tests**

```swift
func testSavingTwoProfilesKeepsTheirTokensSeparate() async throws {
    let secureStore = FakeSecureValueStore()
    let store = RelayConfigurationStore(
        secureStore: secureStore, profileURL: makeTemporaryProfileURL()
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
    XCTAssertNil(try await store.loadToken(for: profile.id))
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
```

If `makeTemporaryProfileURL()` does not already exist in this test file, add it:

```swift
private func makeTemporaryProfileURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("HermesRelayIOS-Profiles-\(UUID().uuidString)")
        .appendingPathComponent("profiles.json")
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Expected: FAIL — `value of type 'RelayConfigurationStore' has no member 'loadCollection'`.

- [ ] **Step 3: Implement collection storage**

Replace the profile-file methods in `RelayConfigurationStore` with collection
equivalents, keeping the existing error mapping:

```swift
    static func tokenAccount(for id: UUID) -> String { id.uuidString }

    func loadCollection() async throws -> RelayProfileCollection {
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            return RelayProfileCollection()
        }
        let data = try Data(contentsOf: profileURL)
        do {
            return try JSONDecoder().decode(RelayProfileCollection.self, from: data)
        } catch is DecodingError {
            // Task 4 handles the legacy single-profile shape here.
            throw RelayConfigurationError.invalidProfile
        }
    }

    func saveCollection(_ collection: RelayProfileCollection) async throws {
        let directoryURL = profileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
        try JSONEncoder().encode(collection).write(to: profileURL, options: .atomic)
    }

    func saveProfile(_ profile: RelayProfile) async throws {
        var collection = try await loadCollection()
        collection.upsert(profile)
        if collection.selectedID == nil {
            collection.selectedID = profile.id
        }
        try await saveCollection(collection)
    }

    func deleteProfile(id: UUID) async throws {
        var collection = try await loadCollection()
        collection.remove(id: id)
        try await saveCollection(collection)
        try secureStore.delete(
            service: Self.keychainService, account: Self.tokenAccount(for: id)
        )
    }

    func selectProfile(id: UUID) async throws {
        var collection = try await loadCollection()
        guard collection.profiles.contains(where: { $0.id == id }) else {
            throw RelayConfigurationError.invalidProfile
        }
        collection.selectedID = id
        try await saveCollection(collection)
    }

    func loadToken(for id: UUID) async throws -> String? {
        try normalizedToken(
            secureStore.read(
                service: Self.keychainService, account: Self.tokenAccount(for: id)
            )
        )
    }

    func saveToken(_ token: String, for id: UUID) async throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw RelayConfigurationError.emptyToken }
        try secureStore.write(
            Data(normalized.utf8),
            service: Self.keychainService,
            account: Self.tokenAccount(for: id)
        )
    }

    private func normalizedToken(_ data: Data?) throws -> String? {
        guard let data else { return nil }
        guard let token = String(data: data, encoding: .utf8) else {
            throw RelayConfigurationError.invalidTokenEncoding
        }
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw RelayConfigurationError.emptyToken }
        return normalized
    }
```

- [ ] **Step 4: Run the tests and watch them pass**

Some existing tests will now fail to compile because `loadProfile()`/`saveProfile()`
changed shape. Leave them broken until Task 5, which restores those accessors —
or, if that is uncomfortable, do Task 5 immediately after this one before running
the full suite.

- [ ] **Step 5: Commit**

```bash
git add HermesRelayIOS/Services/RelayConfigurationStore.swift HermesRelayIOSTests/RelayConfigurationTests.swift
git commit -m "feat: store relay profiles as a collection with per-profile tokens"
```

---

### Task 4: Migrate the existing single profile

**Files:**
- Modify: `HermesRelayIOS/Services/RelayConfigurationStore.swift`
- Test: `HermesRelayIOSTests/RelayConfigurationTests.swift`

**Interfaces:**
- Consumes: Task 3's collection storage.
- Produces: `loadCollection()` transparently migrates a legacy file. No new public API.

This is the task with real stakes: an existing install has a bearer token that
may exist nowhere else.

- [ ] **Step 1: Write the failing tests**

```swift
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
    XCTAssertEqual(try await store.loadToken(for: migrated.id), "legacy-token")
}

func testMigrationLeavesTheTokenRecoverableIfItStopsBeforeDeleting() async throws {
    // The legacy account is only cleared after the copy reads back, so a
    // half-finished migration never loses the secret.
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
    secureStore.failDeletes = true
    let store = RelayConfigurationStore(secureStore: secureStore, profileURL: url)

    let collection = try await store.loadCollection()

    let migrated = try XCTUnwrap(collection.profiles.first)
    XCTAssertEqual(try await store.loadToken(for: migrated.id), "legacy-token")
    XCTAssertNotNil(secureStore.values[legacyKey])
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
```

Extend the fake so a delete failure can be simulated:

```swift
private final class FakeSecureValueStore: SecureValueStore, @unchecked Sendable {
    var values: [String: Data] = [:]
    var failDeletes = false
    // ...existing members...

    func delete(service: String, account: String) throws {
        if failDeletes { throw KeychainError.operationFailed(status: -1, name: "delete") }
        values.removeValue(forKey: "\(service)/\(account)")
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Expected: FAIL — `loadCollection()` throws `invalidProfile` on the legacy file.

- [ ] **Step 3: Implement the migration**

Replace the `catch is DecodingError` branch in `loadCollection()`:

```swift
        do {
            return try JSONDecoder().decode(RelayProfileCollection.self, from: data)
        } catch is DecodingError {
            return try await migrateLegacyProfile(from: data)
        }
```

```swift
    /// Copy, verify, then delete. A crash at any step leaves the token
    /// readable from at least one account, and re-running is safe.
    private func migrateLegacyProfile(from data: Data) async throws -> RelayProfileCollection {
        let legacyProfile: RelayProfile
        do {
            legacyProfile = try JSONDecoder().decode(RelayProfile.self, from: data)
        } catch {
            throw RelayConfigurationError.invalidProfile
        }

        try? FileManager.default.copyItem(
            at: profileURL,
            to: profileURL.appendingPathExtension("legacy-backup")
        )

        if let legacyToken = try normalizedToken(
            secureStore.read(service: Self.keychainService, account: Self.tokenAccount)
        ) {
            try secureStore.write(
                Data(legacyToken.utf8),
                service: Self.keychainService,
                account: Self.tokenAccount(for: legacyProfile.id)
            )
            let verified = try normalizedToken(
                secureStore.read(
                    service: Self.keychainService,
                    account: Self.tokenAccount(for: legacyProfile.id)
                )
            )
            guard verified == legacyToken else {
                throw RelayConfigurationError.invalidProfile
            }
        }

        let collection = RelayProfileCollection(
            profiles: [legacyProfile], selectedID: legacyProfile.id
        )
        try await saveCollection(collection)

        // Only now is the legacy secret redundant. A failure here is not fatal:
        // the token already lives under the profile's own account.
        try? secureStore.delete(
            service: Self.keychainService, account: Self.tokenAccount
        )

        return collection
    }
```

- [ ] **Step 4: Run the tests and watch them pass**

Expected: PASS, all three.

- [ ] **Step 5: Commit**

```bash
git add HermesRelayIOS/Services/RelayConfigurationStore.swift HermesRelayIOSTests/RelayConfigurationTests.swift
git commit -m "feat: migrate the legacy relay profile and token into the collection"
```

---

### Task 5: Restore the selected-profile accessors

**Files:**
- Modify: `HermesRelayIOS/Services/RelayConfigurationStore.swift`
- Test: `HermesRelayIOSTests/RelayConfigurationTests.swift`, `HermesRelayIOSTests/ConversationStoreTransportTests.swift`

**Interfaces:**
- Consumes: Tasks 3 and 4.
- Produces: `func loadProfile() async throws -> RelayProfile?` and `func loadToken() async throws -> String?`, both resolving the selected profile. `ConversationStore.loadConfiguredClient()` is unchanged.

- [ ] **Step 1: Write the failing test**

```swift
func testSelectedProfileAccessorsFollowTheSelection() async throws {
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

    try await store.selectProfile(id: second.id)

    XCTAssertEqual(try await store.loadProfile(), second)
    XCTAssertEqual(try await store.loadToken(), "token-two")
}
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL to compile or return the wrong profile.

- [ ] **Step 3: Implement the accessors**

```swift
    /// The active profile. `ConversationStore` and auto-connect use these, so
    /// they stay unaware that more than one profile exists.
    func loadProfile() async throws -> RelayProfile? {
        try await loadCollection().selectedProfile
    }

    func loadToken() async throws -> String? {
        guard let id = try await loadCollection().selectedID else { return nil }
        return try await loadToken(for: id)
    }
```

- [ ] **Step 4: Run the whole suite**

Fix any existing test that constructed a profile file directly; they should now
go through `saveProfile`. Expected: the full suite passes on both platforms.

- [ ] **Step 5: Commit**

```bash
git add HermesRelayIOS/Services/RelayConfigurationStore.swift HermesRelayIOSTests/
git commit -m "feat: resolve the selected profile through the collection"
```

---

### Task 6: Extract RelayConfigurationView into its own file

**Files:**
- Create: `HermesRelayIOS/Views/RelayConfigurationView.swift`
- Modify: `HermesRelayIOS/Views/ContentView.swift:307-497`, `HermesRelayIOS.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing new.
- Produces: `RelayConfigurationView` at the same call site, with identical behaviour.

Pure move, no behaviour change. Doing it before the UI grows keeps the next
task's diff readable.

- [ ] **Step 1: Move the type**

Cut `struct RelayConfigurationView` and any private helpers it owns out of
`ContentView.swift` into the new file, adding `import SwiftUI`.

- [ ] **Step 2: Add the file to the Xcode project**

As in Task 2 — four pbxproj entries, modelled on `ContentView.swift`'s.

- [ ] **Step 3: Clean, build, and run the suite**

```bash
xcodebuild clean -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS
xcodebuild test -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild build -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=macOS,arch=arm64'
```
Expected: identical test count to before the move, all passing.

- [ ] **Step 4: Commit**

```bash
git add HermesRelayIOS/Views/RelayConfigurationView.swift HermesRelayIOS/Views/ContentView.swift HermesRelayIOS.xcodeproj/project.pbxproj
git commit -m "refactor: move RelayConfigurationView into its own file"
```

---

### Task 7: The profile list

**Files:**
- Modify: `HermesRelayIOS/Views/RelayConfigurationView.swift`
- Test: `HermesRelayIOSTests/RelayConfigurationTests.swift`

**Interfaces:**
- Consumes: `loadCollection`, `saveProfile`, `deleteProfile`, `selectProfile` from Tasks 3–5.
- Produces: `RelayProfileListModel`, an `@Observable @MainActor` type with `private(set) var collection: RelayProfileCollection`, `func load() async`, `func select(id: UUID) async`, `func delete(id: UUID) async`, and `var errorMessage: String?`.

The view is a thin shell over a testable model; assertions live on the model.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL — `cannot find 'RelayProfileListModel' in scope`.

- [ ] **Step 3: Implement the model**

```swift
@MainActor
@Observable
final class RelayProfileListModel {
    private(set) var collection = RelayProfileCollection()
    var errorMessage: String?

    private let configurationStore: RelayConfigurationStore

    init(configurationStore: RelayConfigurationStore) {
        self.configurationStore = configurationStore
    }

    func load() async {
        do {
            collection = try await configurationStore.loadCollection()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(id: UUID) async {
        do {
            try await configurationStore.selectProfile(id: id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(id: UUID) async {
        do {
            try await configurationStore.deleteProfile(id: id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 4: Build the list UI**

In `RelayConfigurationView`, present the profiles above the existing editor:

```swift
    private var profileList: some View {
        ForEach(model.collection.profiles, id: \.id) { profile in
            Button {
                Task { await model.select(id: profile.id) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName)
                        Text(profile.endpoint.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if profile.id == model.collection.selectedID {
                        Image(systemName: "checkmark")
                            .accessibilityLabel("Active profile")
                    }
                }
            }
            .swipeActions {
                Button("Delete", role: .destructive) {
                    Task { await model.delete(id: profile.id) }
                }
            }
        }
    }
```

Tapping a row loads it into the existing editor; an Add action presents the
editor empty. The token field keeps its current behaviour — never rendering a
stored token, offering replacement only.

- [ ] **Step 5: Run tests and both builds**

Expected: PASS on iOS, macOS builds clean.

- [ ] **Step 6: Commit**

```bash
git add HermesRelayIOS/Views/RelayConfigurationView.swift HermesRelayIOSTests/RelayConfigurationTests.swift
git commit -m "feat: list, select, and delete saved relay profiles"
```

---

### Task 8: Switch connections when the selection changes

**Files:**
- Modify: `HermesRelayIOS/ViewModels/ConversationStore.swift`
- Test: `HermesRelayIOSTests/ConversationStoreReconnectTests.swift` — the
  `ReconnectingFakeClient` this test needs is `private` to that file, so the
  test belongs there rather than in `ConversationStoreTransportTests.swift`.

**Interfaces:**
- Consumes: Task 5's selected-profile accessors.
- Produces: `func switchToSelectedProfile() async` on `ConversationStore` — disconnects, reloads the configured client, and connects.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
func testSwitchingProfilesDisconnectsBeforeConnectingTheNewRelay() async {
    let client = ReconnectingFakeClient()
    let store = ConversationStore(client: client)
    await store.connect()

    await store.switchToSelectedProfile()

    XCTAssertEqual(client.disconnectCount, 1)
    XCTAssertEqual(client.connectCount, 2)
    XCTAssertEqual(store.connectionState, .connected)
}
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL — no member `switchToSelectedProfile`.

- [ ] **Step 3: Implement switching**

```swift
    /// Selecting a different profile is one action: drop the current relay and
    /// connect the chosen one. A failure surfaces honestly rather than falling
    /// back to the previous profile, which would connect the user to a relay
    /// they did not choose.
    func switchToSelectedProfile() async {
        isExpectedDisconnect = true
        await client.disconnect()
        isExpectedDisconnect = false
        connectionState = .disconnected
        sessionMetadata = nil
        sessionStartedAt = nil

        guard await loadConfiguredClient() else { return }
        await connect()
    }
```

`isExpectedDisconnect` already exists from IOS-25; without it the reconnect
loop would race this deliberate teardown.

- [ ] **Step 4: Call it from the UI**

In `ContentView`, when the configuration sheet dismisses after a selection
change, call `await store.switchToSelectedProfile()` in place of the current
`loadConfiguredClient()` call.

- [ ] **Step 5: Run tests and both builds**

Expected: PASS on iOS, macOS builds clean.

- [ ] **Step 6: Commit**

```bash
git add HermesRelayIOS/ViewModels/ConversationStore.swift HermesRelayIOS/Views/ContentView.swift HermesRelayIOSTests/ConversationStoreReconnectTests.swift
git commit -m "feat: switch the active relay connection when the profile changes"
```

---

## Manual verification

Automated tests cannot cover the migration on a real Keychain, and that is the
part that matters most.

1. Install the branch build over an existing install that already has a working
   profile. Confirm it still auto-connects without re-entering anything.
2. Add a second profile with a different endpoint. Switch to it, confirm the HUD
   reconnects to the new relay and the session header reflects it.
3. Switch back. Confirm no credential prompt.
4. Delete the inactive profile. Confirm the active one is untouched.
5. Delete the active profile. Confirm the app shows a needs-configuration state
   rather than silently connecting to the remaining profile.
