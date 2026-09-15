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
    private func makeHomeFixture() async throws -> HomeFixture {
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
        let store = ConversationStore(
            configurationStore: configurationStore,
            homeClientFactory: factory,
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
