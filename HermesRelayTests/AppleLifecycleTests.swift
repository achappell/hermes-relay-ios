import Foundation
import XCTest
@testable import HermesRelayIOS

final class AppleLifecycleTests: XCTestCase {
    @MainActor
    func testPersistenceFailureKeepsLifecycleActiveAndDoesNotStopNativeAudio() async {
        let output = LifecycleAudioOutput()
        let store = ConversationStore(persistence: FailingLifecyclePersistence())
        let voice = VoiceSessionCoordinator(
            store: store,
            input: LifecycleSpeechInput(),
            output: output
        )
        let coordinator = AppleLifecycleCoordinator(
            store: store,
            voice: voice,
            homeClientFactory: UnavailableHomeBridgeSessionClientFactory(),
            clock: ContinuousHomeMonotonicClock()
        )

        let result = await coordinator.handle(.inactive)

        XCTAssertEqual(result, .persistenceFailed)
        XCTAssertTrue(store.isLifecycleActive)
        let stopCount = await output.stopCount()
        XCTAssertEqual(stopCount, 0)
    }

    @MainActor
    func testHomeLifecycleOwnsOneCloseAndSuppressesInactiveReconnects() async throws {
        let fixture = try await makeHomeFixture()
        let voice = VoiceSessionCoordinator(
            store: fixture.store,
            input: LifecycleSpeechInput(),
            output: LifecycleAudioOutput()
        )
        let coordinator = AppleLifecycleCoordinator(
            store: fixture.store,
            voice: voice,
            homeClientFactory: fixture.factory,
            clock: ContinuousHomeMonotonicClock()
        )

        let relaunchResult = await coordinator.handle(.relaunch)
        XCTAssertEqual(relaunchResult, .completed)
        XCTAssertTrue(fixture.store.connectionState.isConnected)
        var openCount = await fixture.client.openCount
        XCTAssertEqual(openCount, 1)

        // A repeated active notification is idempotent while the existing
        // ready binding is still owned by the lifecycle coordinator.
        let activeResult = await coordinator.handle(.active)
        XCTAssertEqual(activeResult, .completed)
        openCount = await fixture.client.openCount
        XCTAssertEqual(openCount, 1)

        let inactiveResult = await coordinator.handle(.inactive)
        XCTAssertEqual(inactiveResult, .completed)
        let repeatedInactiveResult = await coordinator.handle(.inactive)
        XCTAssertEqual(repeatedInactiveResult, .completed)
        let closeCount = await fixture.client.closeCount
        XCTAssertEqual(closeCount, 1)

        await fixture.store.connect()
        openCount = await fixture.client.openCount
        XCTAssertEqual(openCount, 1)
    }

    @MainActor
    func testInterleavedInactiveAndActiveLeaveTheStoreActiveAndReconnect() async throws {
        // Scene phases arrive as separate Tasks. An active that lands while
        // the inactive teardown is still running must not be dropped or undone.
        let fixture = try await makeHomeFixture(persistence: SlowLifecyclePersistence())
        let voice = VoiceSessionCoordinator(
            store: fixture.store,
            input: LifecycleSpeechInput(),
            output: LifecycleAudioOutput()
        )
        let coordinator = AppleLifecycleCoordinator(
            store: fixture.store,
            voice: voice,
            homeClientFactory: fixture.factory,
            clock: ContinuousHomeMonotonicClock()
        )
        _ = await coordinator.handle(.relaunch)
        XCTAssertTrue(fixture.store.connectionState.isConnected)

        let inactive = Task { await coordinator.handle(.inactive) }
        let active = Task { await coordinator.handle(.active) }
        _ = await inactive.value
        _ = await active.value

        XCTAssertTrue(fixture.store.isLifecycleActive, "The newer active must win")
        XCTAssertNotNil(
            fixture.store.currentHomeClientForLifecycle(),
            "The active surface keeps or reopens its Home bridge"
        )
        XCTAssertNotNil(coordinator.activeHomeClient)

        // An active that arrives mid-teardown waits for it, then reactivates.
        let openCountBefore = await fixture.client.openCount
        let midInactive = Task { await coordinator.handle(.inactive) }
        try await Task.sleep(for: .milliseconds(10))
        let midActive = Task { await coordinator.handle(.active) }
        _ = await midInactive.value
        _ = await midActive.value

        XCTAssertTrue(fixture.store.isLifecycleActive, "A stale teardown must not undo the newer active")
        let openCountAfter = await fixture.client.openCount
        XCTAssertEqual(openCountAfter, openCountBefore + 1, "The newer active reopens after the teardown")
    }

    @MainActor
    func testBackgroundLeavesTheStoreDisconnectedAndForegroundReopensTheClaim() async throws {
        // Pilot 2026-10-04: after a background the HUD still said Connected
        // over a closed transport, and talking failed.
        let factory = FreshHomeClientFactory()
        let fixture = try await makeHomeFixture(factory: factory)
        let coordinator = makeCoordinator(fixture.store, factory: factory)
        _ = await coordinator.handle(.relaunch)
        XCTAssertTrue(fixture.store.connectionState.isConnected)

        _ = await coordinator.handle(.inactive)
        _ = await coordinator.handle(.background)

        XCTAssertEqual(fixture.store.connectionState, .disconnected)
        XCTAssertNotEqual(
            ConversationDoorwayState(connectionState: fixture.store.connectionState, profileName: "Test Apple"),
            .connected
        )
        XCTAssertNil(fixture.store.verifiedTurnBinding, "Tap-to-talk cannot start over a closed transport")

        _ = await coordinator.handle(.inactive)
        _ = await coordinator.handle(.active)

        XCTAssertTrue(fixture.store.connectionState.isConnected)
        XCTAssertEqual(factory.clients.count, 2, "Foreground opens a new transport")
        let reopened = await factory.clients.last?.openCount
        XCTAssertEqual(reopened, 1)
        XCTAssertNotNil(fixture.store.verifiedTurnBinding)
    }

    @MainActor
    func testActiveWithAStaleConnectedStateButNoLiveTransportReconnects() async throws {
        let factory = FreshHomeClientFactory()
        let fixture = try await makeHomeFixture(factory: factory)
        let coordinator = makeCoordinator(fixture.store, factory: factory)
        _ = await coordinator.handle(.relaunch)
        XCTAssertTrue(fixture.store.connectionState.isConnected)

        // The transport is gone without a completed lifecycle teardown.
        let lost = fixture.store.takeHomeClientForLifecycle()
        await lost?.close()
        XCTAssertNil(fixture.store.verifiedTurnBinding)

        _ = await coordinator.handle(.active)

        XCTAssertTrue(fixture.store.connectionState.isConnected)
        XCTAssertNotNil(fixture.store.currentHomeClientForLifecycle())
        XCTAssertEqual(factory.clients.count, 2)
        XCTAssertNotNil(fixture.store.verifiedTurnBinding)
    }

    @MainActor
    private func makeCoordinator(
        _ store: ConversationStore,
        factory: any HomeBridgeSessionClientFactory
    ) -> AppleLifecycleCoordinator {
        AppleLifecycleCoordinator(
            store: store,
            voice: VoiceSessionCoordinator(
                store: store,
                input: LifecycleSpeechInput(),
                output: LifecycleAudioOutput()
            ),
            homeClientFactory: factory,
            clock: ContinuousHomeMonotonicClock()
        )
    }

    @MainActor
    private func makeHomeFixture(
        persistence: (any ConversationPersistence)? = nil,
        factory freshFactory: FreshHomeClientFactory? = nil
    ) async throws -> HomeFixture {
        let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let profile = try RelayProfile(
            id: profileID,
            endpoint: URL(string: "wss://legacy.example/session")!,
            clientID: "hermes-apple",
            deviceID: "apple-device",
            displayName: "Test Apple"
        )
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesLifecycle-(UUID().uuidString)")
            .appendingPathExtension("json")
        let configurationStore = RelayConfigurationStore(
            secureStore: LifecycleSecureValueStore(),
            profileURL: profileURL
        )
        let journal = HomeMigrationJournal(
            schemaVersion: 1,
            profileID: profileID,
            phase: .homeSelected,
            selectedMode: .home,
            credential: nil,
            legacyCredentialRetained: true,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        try await configurationStore.saveCollection(
            RelayProfileCollection(
                profiles: [profile],
                selectedID: profileID,
                homeMigrations: [profileID: journal]
            )
        )
        let claim = HomeDemoFixtures.claim(for: profileID)
        let client = FakeHomeBridgeSessionClient(claim: claim)
        let factory = FakeHomeBridgeSessionClientFactory(client: client)
        freshFactory?.claim = claim
        let store = ConversationStore(
            configurationStore: configurationStore,
            persistence: persistence,
            homeClientFactory: freshFactory ?? factory,
            homeClaimProvider: StaticHomeConversationClaimProvider(claim: claim)
        )
        return HomeFixture(
            store: store,
            client: client,
            factory: factory
        )
    }
}

@MainActor
private struct HomeFixture {
    let store: ConversationStore
    let client: FakeHomeBridgeSessionClient
    let factory: FakeHomeBridgeSessionClientFactory
}

/// Makes a new transport per connection, as the live factory does.
private final class FreshHomeClientFactory: HomeBridgeSessionClientFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeHomeBridgeSessionClient] = []
    var claim: HomeConversationClaim?

    var clients: [FakeHomeBridgeSessionClient] {
        lock.lock(); defer { lock.unlock() }
        return made
    }

    func make(profileID: UUID, mode: AppleTransportMode) -> any HomeBridgeSessionClient {
        lock.lock(); defer { lock.unlock() }
        let client = FakeHomeBridgeSessionClient(claim: claim ?? HomeDemoFixtures.claim(for: profileID))
        made.append(client)
        return client
    }
}

/// Saving takes real time, so lifecycle work suspends mid-teardown.
private actor SlowLifecyclePersistence: ConversationPersistence {
    func load() async throws -> PersistedConversation {
        PersistedConversation(messages: [], draft: "")
    }

    func save(_ conversation: PersistedConversation) async throws {
        try await Task.sleep(for: .milliseconds(50))
    }
}

private actor LifecycleSpeechInput: SpeechInput {
    func authorization() async -> SpeechAuthorization { .authorized }
    func requestAuthorization() async -> SpeechAuthorization { .authorized }
    func start() async throws -> AsyncThrowingStream<SpeechRecognitionUpdate, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
    func finish() async {}
    func cancel() async {}
}

private actor LifecycleAudioOutput: AudioOutput {
    private var stops = 0

    func start(format: AudioFormat) async throws {}
    func append(_ pcm: Data) async throws -> AudioPlaybackReadiness { .ready }
    func finish() async throws {}
    func stop() async { stops += 1 }
    func playbackPosition() async -> TimeInterval? { nil }
    func stopCount() -> Int { stops }
}

private actor FailingLifecyclePersistence: ConversationPersistence {
    func load() async throws -> PersistedConversation {
        PersistedConversation(messages: [], draft: "")
    }

    func save(_ conversation: PersistedConversation) async throws {
        throw LifecyclePersistenceError.failed
    }
}

private enum LifecyclePersistenceError: Error {
    case failed
}

private final class LifecycleSecureValueStore: SecureValueStore, @unchecked Sendable {
    func read(service: String, account: String) throws -> Data? { nil }
    func write(_ value: Data, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}
