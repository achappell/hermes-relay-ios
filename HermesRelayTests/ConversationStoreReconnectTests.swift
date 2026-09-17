import Foundation
import XCTest
@testable import HermesRelayIOS

final class ConversationStoreReconnectTests: XCTestCase {
    @MainActor
    func testUnexpectedLossRetriesWithBoundedBackoffThenReportsExhaustion() async {
        let client = ReconnectingFakeClient()
        let sleeps = SleepRecorder()
        let store = makeStore(client: client, sleeps: sleeps)
        await store.connect()
        client.connectResults = Array(repeating: .failure(ReconnectFakeError.offline), count: 5)

        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()

        XCTAssertEqual(
            sleeps.recorded,
            [500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000]
        )
        XCTAssertEqual(client.connectCount, 6)
        XCTAssertEqual(store.connectionState, .failed("The test relay is offline."))
    }

    @MainActor
    func testExhaustedReconnectStillAllowsAManualRetry() async {
        let client = ReconnectingFakeClient()
        let store = makeStore(client: client, sleeps: SleepRecorder())
        await store.connect()
        client.connectResults = Array(repeating: .failure(ReconnectFakeError.offline), count: 5)

        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()
        client.connectResults = []
        await store.connect()

        XCTAssertEqual(store.connectionState, .connected)
    }

    @MainActor
    func testReconnectRecoversAndSurfacesReconnectingProgress() async {
        let client = ReconnectingFakeClient()
        let sleeps = SleepRecorder()
        let store = makeStore(client: client, sleeps: sleeps)
        await store.connect()
        client.connectResults = [
            .failure(ReconnectFakeError.offline),
            .failure(ReconnectFakeError.offline),
        ]
        var observed: [ConnectionState] = []
        sleeps.onSleep = { @MainActor in observed.append(store.connectionState) }

        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()

        XCTAssertEqual(
            observed,
            [.reconnecting(attempt: 1, of: 5), .reconnecting(attempt: 2, of: 5), .reconnecting(attempt: 3, of: 5)]
        )
        XCTAssertEqual(sleeps.recorded, [500_000_000, 1_000_000_000, 2_000_000_000])
        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(store.sessionMetadata?.sessionID, "session-4")
    }

    @MainActor
    func testReconnectPreservesTranscriptAndDraft() async {
        let client = ReconnectingFakeClient()
        let store = makeStore(client: client, sleeps: SleepRecorder())
        await store.connect()
        await store.sendTurn(text: "keep me")
        store.draft = "half typed"

        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()

        XCTAssertEqual(store.messages.first?.text, "keep me")
        XCTAssertEqual(store.draft, "half typed")
        XCTAssertEqual(store.connectionState, .connected)
    }

    @MainActor
    func testReconnectNeverReplaysAnInFlightTurn() async {
        let client = ReconnectingFakeClient()
        let store = makeStore(client: client, sleeps: SleepRecorder())
        await store.connect()
        client.sendError = RelaySessionError.disconnected

        await store.sendTurn(text: "did this arrive")
        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()

        XCTAssertEqual(client.sentTurns, ["did this arrive"])
        XCTAssertEqual(store.unconfirmedTurnText, "did this arrive")
        XCTAssertEqual(store.connectionState, .connected)
    }

    @MainActor
    func testResendingTheUnconfirmedTurnSendsItOnceAndClearsTheMarker() async throws {
        let client = ReconnectingFakeClient()
        let store = makeStore(client: client, sleeps: SleepRecorder())
        await store.connect()
        client.sendError = RelaySessionError.disconnected
        await store.sendTurn(text: "did this arrive")
        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()
        client.sendError = nil

        let unconfirmed = try XCTUnwrap(store.unconfirmedTurnText)
        await store.sendTurn(text: unconfirmed)

        XCTAssertEqual(client.sentTurns, ["did this arrive", "did this arrive"])
        XCTAssertNil(store.unconfirmedTurnText)
    }

    @MainActor
    func testUnrecoverableConfigurationFailureStopsRetrying() async {
        let client = ReconnectingFakeClient()
        let sleeps = SleepRecorder()
        let store = makeStore(client: client, sleeps: sleeps)
        await store.connect()
        client.connectResults = Array(repeating: .failure(RelayUnavailableError()), count: 5)

        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()

        XCTAssertEqual(sleeps.recorded, [500_000_000])
        XCTAssertEqual(client.connectCount, 2)
        XCTAssertEqual(store.connectionState, .failed(RelayUnavailableError().localizedDescription))
    }

    @MainActor
    func testInterruptingATurnDoesNotStartAReconnectLoop() async {
        let client = ReconnectingFakeClient()
        let sleeps = SleepRecorder()
        let store = makeStore(client: client, sleeps: sleeps)
        await store.connect()

        _ = await store.interruptActiveTurn()

        XCTAssertEqual(sleeps.recorded, [])
        XCTAssertFalse(store.isReconnecting)
    }

    @MainActor
    func testASecondLossWhileReconnectingDoesNotStackAttempts() async {
        let client = ReconnectingFakeClient()
        let sleeps = SleepRecorder()
        let store = makeStore(client: client, sleeps: sleeps)
        await store.connect()
        client.connectResults = [.failure(ReconnectFakeError.offline)]
        sleeps.onSleep = { @MainActor in store.handleUnexpectedTransportLoss() }

        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()

        XCTAssertEqual(sleeps.recorded, [500_000_000, 1_000_000_000])
        XCTAssertEqual(client.connectCount, 3)
        XCTAssertEqual(store.connectionState, .connected)
    }

    @MainActor
    func testHomeReconnectDoesNotReplayAnUncertainPrompt() async throws {
        let fixture = try await makeHomeReconnectReviewFixture()
        defer { try? FileManager.default.removeItem(at: fixture.profileURL.deletingLastPathComponent()) }
        await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        await fixture.firstClient.setNextSubmissionOutcome(
            .uncertain(.home(code: .transportTimeout, phase: .submission))
        )

        let completed = await fixture.store.sendTurn(text: "maybe sent")

        XCTAssertFalse(completed)
        await fixture.store.connect()
        let firstSubmittedTexts = await fixture.firstClient.submittedTexts
        let secondSubmittedTexts = await fixture.secondClient.submittedTexts
        XCTAssertEqual(firstSubmittedTexts, ["maybe sent"])
        XCTAssertEqual(secondSubmittedTexts, [])
        XCTAssertEqual(fixture.store.connectionState, .connected)
        XCTAssertEqual(fixture.store.homeTurnDeliveryState, .uncertain(nil))
        XCTAssertTrue(fixture.store.canContinueWithoutResendingHomeTurn)
    }

    @MainActor
    func testAutomaticHomeReconnectCanReleaseConfirmedInactiveRecovery() async throws {
        let fixture = try await makeHomeReconnectReviewFixture()
        defer { try? FileManager.default.removeItem(at: fixture.profileURL.deletingLastPathComponent()) }
        await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        await fixture.firstClient.setNextSubmissionOutcome(
            .uncertain(.home(code: .transportTimeout, phase: .submission))
        )
        _ = await fixture.store.sendTurn(text: "maybe sent")

        fixture.store.handleUnexpectedTransportLoss()
        await fixture.store.waitForReconnectToFinish()

        XCTAssertEqual(fixture.store.connectionState, .connected)
        XCTAssertTrue(fixture.store.canContinueWithoutResendingHomeTurn)
    }

    @MainActor
    func testAnOmittedNoTurnStateCannotReleaseUnconfirmedHomeRecovery() async throws {
        let fixture = try await makeHomeReconnectReviewFixture()
        defer { try? FileManager.default.removeItem(at: fixture.profileURL.deletingLastPathComponent()) }
        await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        await fixture.firstClient.setNextSubmissionOutcome(
            .uncertain(.home(code: .transportTimeout, phase: .submission))
        )
        _ = await fixture.store.sendTurn(text: "maybe sent")
        await fixture.secondClient.setReconnectConfirmsNoUnresolvedTurn(false)

        await fixture.store.connect()

        XCTAssertFalse(fixture.store.canContinueWithoutResendingHomeTurn)
        let continued = await fixture.store.continueWithoutResendingHomeTurn()
        XCTAssertFalse(continued)
        XCTAssertEqual(fixture.store.unconfirmedTurnText, "maybe sent")
    }

    @MainActor
    func testHomeConfirmedInactiveRecoveryCanBeClearedWithoutResending() async throws {
        let fixture = try await makeHomeReconnectReviewFixture()
        defer { try? FileManager.default.removeItem(at: fixture.profileURL.deletingLastPathComponent()) }
        await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        await fixture.firstClient.setNextSubmissionOutcome(
            .uncertain(.home(code: .transportTimeout, phase: .submission))
        )
        _ = await fixture.store.sendTurn(text: "maybe sent")
        fixture.store.draft = "fresh Home turn"

        await fixture.store.connect()

        XCTAssertTrue(fixture.store.canContinueWithoutResendingHomeTurn)
        let blockedSend = await fixture.store.sendTurn(text: "fresh Home turn")
        XCTAssertFalse(blockedSend)
        let beforeContinue = await fixture.secondClient.submittedTexts
        XCTAssertEqual(beforeContinue, [])
        let continued = await fixture.store.continueWithoutResendingHomeTurn()
        XCTAssertTrue(continued)
        XCTAssertNil(fixture.store.unconfirmedTurnText)
        XCTAssertEqual(fixture.store.homeTurnDeliveryState, .idle)
        XCTAssertEqual(fixture.store.draft, "fresh Home turn")
        XCTAssertEqual(fixture.store.messages.first?.text, "maybe sent")
        XCTAssertTrue(fixture.store.messages.last?.text.contains("It was not resent") == true)

        await fixture.secondClient.setNextSubmissionOutcome(
            .rejected(.home(code: .requestRejected, phase: .submission))
        )
        let newSend = await fixture.store.sendTurn(text: "fresh Home turn")
        XCTAssertFalse(newSend)
        let afterContinue = await fixture.secondClient.submittedTexts
        XCTAssertEqual(afterContinue, ["fresh Home turn"])
    }



    // Switching must clear the previous account's transcript before the new
    // one loads. Loading first would flash the wrong conversation, which is
    // the whole point of per-profile history.
    @MainActor
    func testSwitchingProfilesClearsTheTranscriptBeforeLoading() async {
        let client = ReconnectingFakeClient()
        let store = ConversationStore(client: client)
        await store.connect()
        await store.sendTurn(text: "belongs to the first account")
        XCTAssertFalse(store.messages.isEmpty)
        store.draft = "half typed"
        store.unconfirmedTurnText = "in flight"

        await store.switchToSelectedProfile()

        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.draft, "")
        XCTAssertNil(store.unconfirmedTurnText)
    }

    @MainActor
    private func makeStore(client: ReconnectingFakeClient, sleeps: SleepRecorder) -> ConversationStore {
        ConversationStore(
            client: client,
            reconnectPolicy: .default,
            sleep: { nanoseconds in await sleeps.record(nanoseconds) }
        )
    }

    @MainActor
    private func makeHomeReconnectReviewFixture() async throws -> HomeReconnectReviewFixture {
        let profileID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let profile = try RelayProfile(
            id: profileID,
            endpoint: URL(string: "wss://legacy.example/session")!,
            clientID: "hermes-apple",
            deviceID: "apple-device",
            displayName: "Test Apple"
        )
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesRelayIOS-HomeReconnectReview-\(UUID().uuidString)")
            .appendingPathExtension("json")
        let configurationStore = RelayConfigurationStore(
            secureStore: HomeReconnectReviewSecureValueStore(),
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
        let firstClient = FakeHomeBridgeSessionClient(claim: claim)
        let secondClient = FakeHomeBridgeSessionClient(claim: claim)
        let store = ConversationStore(
            configurationStore: configurationStore,
            homeClientFactory: RotatingHomeBridgeSessionClientFactory(
                clients: [firstClient, secondClient]
            ),
            homeClaimProvider: StaticHomeConversationClaimProvider(claim: claim)
        )
        return HomeReconnectReviewFixture(
            store: store,
            firstClient: firstClient,
            secondClient: secondClient,
            profileURL: profileURL
        )
    }
}

@MainActor
private struct HomeReconnectReviewFixture {
    let store: ConversationStore
    let firstClient: FakeHomeBridgeSessionClient
    let secondClient: FakeHomeBridgeSessionClient
    let profileURL: URL
}

private final class HomeReconnectReviewSecureValueStore: SecureValueStore, @unchecked Sendable {
    func read(service: String, account: String) throws -> Data? { nil }
    func write(_ value: Data, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}

private final class RotatingHomeBridgeSessionClientFactory: HomeBridgeSessionClientFactory, @unchecked Sendable {
    private let clients: [any HomeBridgeSessionClient]
    private let lock = NSLock()
    private var nextIndex = 0

    init(clients: [any HomeBridgeSessionClient]) {
        self.clients = clients
    }

    func make(profileID: UUID, mode: AppleTransportMode) -> any HomeBridgeSessionClient {
        lock.lock()
        defer { lock.unlock() }
        let client = clients[min(nextIndex, clients.count - 1)]
        nextIndex += 1
        return client
    }
}

private enum ReconnectFakeError: LocalizedError, Sendable {
    case offline

    var errorDescription: String? { "The test relay is offline." }
}

@MainActor
private final class SleepRecorder {
    private(set) var recorded: [UInt64] = []
    var onSleep: (@MainActor () -> Void)?

    func record(_ nanoseconds: UInt64) async {
        recorded.append(nanoseconds)
        onSleep?()
    }
}

@MainActor
private final class ReconnectingFakeClient: HermesSessionClient {
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var sentTurns: [String] = []
    var connectResults: [Result<SessionMetadata, Error>] = []
    var sendError: Error?

    nonisolated func connect() async throws -> SessionMetadata {
        try await MainActor.run {
            connectCount += 1
            if !connectResults.isEmpty {
                let result = connectResults.removeFirst()
                return try result.get()
            }
            return SessionMetadata(sessionID: "session-\(connectCount)", model: nil)
        }
    }

    nonisolated func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error> {
        let failure = await MainActor.run { () -> Error? in
            sentTurns.append(text)
            return sendError
        }
        return AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.yield(.turnComplete(turnID: "turn-1"))
                continuation.finish()
            }
        }
    }

    nonisolated func disconnect() async {
        await MainActor.run { disconnectCount += 1 }
    }
}
