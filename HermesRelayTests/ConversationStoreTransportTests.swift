import Foundation
import XCTest
@testable import HermesRelayIOS

final class ConversationStoreTransportTests: XCTestCase {
    @MainActor
    func testConnectStoresMetadataWhenClientConnects() async {
        let client = FakeHermesSessionClient()
        client.connectResult = .success(SessionMetadata(sessionID: "session-1", model: "test-model"))
        let startedAt = Date(timeIntervalSince1970: 42)
        let store = ConversationStore(client: client, now: { startedAt })

        await store.connect()

        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(store.sessionMetadata, SessionMetadata(sessionID: "session-1", model: "test-model"))
        XCTAssertEqual(store.sessionStartedAt, startedAt)
    }

    @MainActor
    func testConnectionFailureIsVisible() async {
        let client = FakeHermesSessionClient()
        client.connectResult = .failure(FakeClientError.offline)
        let store = ConversationStore(client: client)

        await store.connect()

        XCTAssertEqual(store.connectionState, .failed("The test relay is offline."))
        XCTAssertEqual(store.transientError, "The test relay is offline.")
        XCTAssertNil(store.sessionMetadata)
    }

    @MainActor
    func testSendTurnUpdatesOneAssistantForStreamedText() async {
        let client = FakeHermesSessionClient()
        client.connectResult = .success(SessionMetadata(sessionID: "session-1", model: nil))
        client.eventsByText["Hello Hermes"] = [
            .messageStart,
            .textDelta("Hello "),
            .textDelta("Hermes"),
            .turnComplete(turnID: "turn-1"),
        ]
        let store = ConversationStore(client: client)
        await store.connect()

        await store.sendTurn(text: "Hello Hermes")

        XCTAssertEqual(client.sentTurns, ["Hello Hermes"])
        XCTAssertEqual(store.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(store.messages.last?.text, "Hello Hermes")
        XCTAssertFalse(store.isSending)
    }

    @MainActor
    func testTextReplacementChangesActiveAssistantWithoutAppending() async {
        let client = FakeHermesSessionClient()
        client.connectResult = .success(SessionMetadata(sessionID: "session-1", model: nil))
        client.eventsByText["revise"] = [
            .messageStart,
            .textDelta("Draft"),
            .textReplace("Final"),
            .turnComplete(turnID: "turn-1"),
        ]
        let store = ConversationStore(client: client)
        await store.connect()

        await store.sendTurn(text: "revise")

        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(store.messages.last?.text, "Final")
    }

    @MainActor
    func testStatusDoesNotBecomeTranscriptAndClearsAtTurnCompletion() async {
        let client = FakeHermesSessionClient()
        client.connectResult = .success(SessionMetadata(sessionID: "session-1", model: nil))
        client.eventsByText["status"] = [
            .status(text: "Working", kind: "tool"),
            .messageStart,
            .textDelta("Done"),
            .turnComplete(turnID: "turn-1"),
        ]
        let store = ConversationStore(client: client)
        await store.connect()

        await store.sendTurn(text: "status")

        XCTAssertNil(store.activityText)
        XCTAssertEqual(store.messages.count, 2)
        XCTAssertFalse(store.messages.contains { $0.text == "Working" })
    }

    @MainActor
    func testStatusClearsWhenTheEventStreamEndsWithoutATerminalEvent() async {
        let client = FakeHermesSessionClient()
        client.connectResult = .success(SessionMetadata(sessionID: "session-1", model: nil))
        client.eventsByText["truncated"] = [
            .status(text: "Still working", kind: "tool"),
            .messageStart,
            .textDelta("Partial answer"),
        ]
        let store = ConversationStore(client: client)
        await store.connect()

        let completed = await store.sendTurn(text: "truncated")

        XCTAssertFalse(completed)
        XCTAssertNil(store.activityText)
        XCTAssertEqual(store.unconfirmedTurnText, "truncated")
    }

    @MainActor
    func testServerErrorIsVisibleAndTurnEndsSendingState() async {
        let client = FakeHermesSessionClient()
        client.connectResult = .success(SessionMetadata(sessionID: "session-1", model: nil))
        client.eventsByText["fail"] = [.error("Relay failed")]
        let store = ConversationStore(client: client)
        await store.connect()

        await store.sendTurn(text: "fail")

        XCTAssertEqual(store.transientError, "Relay failed")
        XCTAssertEqual(store.messages.last?.role, .error)
        XCTAssertFalse(store.isSending)
    }

    @MainActor
    func testDisconnectedTurnClearsTheStaleConnectedState() async {
        let client = FakeHermesSessionClient()
        client.connectResult = .success(SessionMetadata(sessionID: "session-1", model: nil))
        client.sendError = RelaySessionError.disconnected
        let store = ConversationStore(client: client)
        await store.connect()

        let completed = await store.sendTurn(text: "hello")

        XCTAssertFalse(completed)
        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertNil(store.sessionMetadata)
        XCTAssertFalse(store.isSending)
    }

    @MainActor
    func testInterruptingActiveTurnReconnectsWithoutSurfacingTransportFailure() async {
        let client = InterruptibleHermesSessionClient()
        let store = ConversationStore(client: client)
        await store.connect()

        let sendTask = Task { @MainActor in
            await store.sendTurn(text: "Keep listening")
        }
        await client.waitUntilTurnStarted()

        let didInterrupt = await store.interruptActiveTurn()
        let didComplete = await sendTask.value
        let disconnectCount = await client.disconnectCount
        let connectCount = await client.connectCount

        XCTAssertTrue(didInterrupt)
        XCTAssertFalse(didComplete)
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertFalse(store.isSending)
        XCTAssertEqual(store.messages.map(\.role), [.user])
        XCTAssertNil(store.activityText)
        XCTAssertEqual(
            store.unconfirmedTurnText,
            "Keep listening",
            "Legacy close-and-reconnect interruption is not server-confirmed"
        )
        XCTAssertNil(store.transientError)
    }

    @MainActor
    func testServerConfirmedInterruptKeepsConnectionAndDoesNotMarkTurnUnconfirmed() async {
        let client = ServerInterruptHermesSessionClient()
        let store = ConversationStore(client: client)
        await store.connect()

        let sendTask = Task { @MainActor in
            await store.sendTurn(text: "Stop that answer")
        }
        await client.waitUntilTurnStarted()

        let didInterrupt = await store.interruptActiveTurn()
        let didComplete = await sendTask.value
        let disconnectCount = await client.disconnectCount
        let interruptCount = await client.interruptCount

        XCTAssertTrue(didInterrupt)
        XCTAssertFalse(didComplete)
        XCTAssertEqual(disconnectCount, 0)
        XCTAssertEqual(interruptCount, 1)
        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertFalse(store.isSending)
        XCTAssertEqual(store.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(store.messages.last?.text, "partial answer")
        XCTAssertNil(store.unconfirmedTurnText)
        XCTAssertNil(store.transientError)
    }

    @MainActor
    func testSendDraftClearsComposerWhenTurnIsAccepted() async {
        let client = InterruptibleHermesSessionClient()
        let persistence = DraftRecordingPersistence()
        let store = ConversationStore(client: client, persistence: persistence)
        await store.connect()
        store.draft = "Keep listening"

        let sendTask = Task { @MainActor in
            await store.sendDraft()
        }
        await client.waitUntilTurnStarted()

        XCTAssertEqual(store.draft, "")

        _ = await store.interruptActiveTurn()
        _ = await sendTask.value

        XCTAssertEqual(store.draft, "Keep listening")
        let saved = await persistence.lastSaved()
        XCTAssertEqual(saved?.draft, "Keep listening")
    }


    // Switching profiles is one action: drop the current relay and connect the
    // newly selected one. Exercised here rather than against a fake client
    // because the connect half runs through the real configuration path.
    @MainActor
    func testSwitchingProfilesConnectsTheNewlySelectedRelay() async throws {
        let profileURL = temporaryProfileURL()
        defer { try? FileManager.default.removeItem(at: profileURL.deletingLastPathComponent()) }

        let configuration = RelayConfigurationStore(
            secureStore: AutoConnectSecureValueStore(),
            profileURL: profileURL
        )
        let first = try RelayProfile(
            endpoint: URL(string: "wss://one.example.test/session")!,
            clientID: "hermes-ios", deviceID: "device-1", displayName: "One"
        )
        let second = try RelayProfile(
            endpoint: URL(string: "wss://two.example.test/session")!,
            clientID: "hermes-ios", deviceID: "device-2", displayName: "Two"
        )
        try await configuration.saveProfile(first)
        try await configuration.saveToken("token-one", for: first.id)
        try await configuration.saveProfile(second)
        try await configuration.saveToken("token-two", for: second.id)

        let socket = AutoConnectWebSocketConnection()
        let factory = AutoConnectWebSocketConnectionFactory(
            socket: socket,
            makeSocket: { AutoConnectWebSocketConnection() }
        )
        let store = ConversationStore(
            configurationStore: configuration,
            socketFactory: factory
        )

        await store.autoConnectIfNeeded()
        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(factory.openCount, 1)

        try await configuration.selectProfile(id: second.id)
        await store.switchToSelectedProfile()

        XCTAssertEqual(store.connectionState, .connected)
        // A second socket was opened, which is the switch actually happening
        // rather than the old connection being reused.
        XCTAssertEqual(factory.openCount, 2)
        XCTAssertEqual(
            factory.lastRequest?.url,
            URL(string: "wss://two.example.test/session")
        )

        for opened in factory.openedSockets {
            await opened.close()
        }
    }

    @MainActor
    func testClearingSelectedProfileDropsLiveSessionAndConversationState() async throws {
        let profileURL = temporaryProfileURL()
        defer { try? FileManager.default.removeItem(at: profileURL.deletingLastPathComponent()) }

        let configuration = RelayConfigurationStore(
            secureStore: AutoConnectSecureValueStore(),
            profileURL: profileURL
        )
        let profile = try RelayProfile(
            endpoint: URL(string: "wss://one.example.test/session")!,
            clientID: "hermes-ios",
            deviceID: "device-1",
            displayName: "One"
        )
        try await configuration.saveProfile(profile)
        try await configuration.saveToken("token-one", for: profile.id)

        let client = FakeHermesSessionClient()
        let store = ConversationStore(client: client, configurationStore: configuration)
        await store.autoConnectIfNeeded()
        store.messages = [TranscriptMessage(role: .user, text: "private")]
        store.draft = "half typed"
        store.unconfirmedTurnText = "in flight"

        try await configuration.deleteProfile(id: profile.id)
        await store.clearSelectedProfile()

        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertNil(store.activeProfileID)
        XCTAssertNil(store.activeProfileDisplayName)
        XCTAssertNil(store.sessionMetadata)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.draft, "")
        XCTAssertNil(store.unconfirmedTurnText)
        XCTAssertFalse(store.isSending)
        XCTAssertNil(store.transientError)
    }

    @MainActor
    func testAutoConnectUsesStoredConfigurationOnlyOnce() async throws {
        let profileURL = temporaryProfileURL()
        defer { try? FileManager.default.removeItem(at: profileURL.deletingLastPathComponent()) }

        let configuration = RelayConfigurationStore(
            secureStore: AutoConnectSecureValueStore(),
            profileURL: profileURL
        )
        let profile = try RelayProfile(
            endpoint: URL(string: "wss://relay.example.test/session")!,
            clientID: "hermes-ios",
            deviceID: "device-123",
            displayName: "Test iPhone"
        )
        try await configuration.saveProfile(profile)
        try await configuration.saveToken("test-token", for: profile.id)

        let socket = AutoConnectWebSocketConnection()
        let factory = AutoConnectWebSocketConnectionFactory(socket: socket)
        let store = ConversationStore(
            configurationStore: configuration,
            socketFactory: factory
        )

        let firstAttempt = Task { @MainActor in
            await store.autoConnectIfNeeded()
        }
        let secondAttempt = Task { @MainActor in
            await store.autoConnectIfNeeded()
        }
        await firstAttempt.value
        await secondAttempt.value

        XCTAssertEqual(factory.openCount, 1)
        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(socket.sentTexts.count, 1)
        XCTAssertEqual(store.activeProfileDisplayName, "Test iPhone")

        await socket.close()
    }

    @MainActor
    func testAutoConnectDoesNotAttemptWithoutAStoredProfile() async throws {
        let profileURL = temporaryProfileURL()
        defer { try? FileManager.default.removeItem(at: profileURL.deletingLastPathComponent()) }

        let configuration = RelayConfigurationStore(
            secureStore: AutoConnectSecureValueStore(),
            profileURL: profileURL
        )
        let factory = AutoConnectWebSocketConnectionFactory(socket: AutoConnectWebSocketConnection())
        let store = ConversationStore(
            configurationStore: configuration,
            socketFactory: factory
        )

        await store.autoConnectIfNeeded()

        XCTAssertEqual(factory.openCount, 0)
        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertEqual(store.transientError, "Configure a Hermes relay profile before connecting.")
    }

    @MainActor
    func testAutoConnectDoesNotAttemptWithAMalformedProfile() async throws {
        let profileURL = temporaryProfileURL()
        defer { try? FileManager.default.removeItem(at: profileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: profileURL)

        let configuration = RelayConfigurationStore(
            secureStore: AutoConnectSecureValueStore(),
            profileURL: profileURL
        )
        let factory = AutoConnectWebSocketConnectionFactory(socket: AutoConnectWebSocketConnection())
        let store = ConversationStore(
            configurationStore: configuration,
            socketFactory: factory
        )

        await store.autoConnectIfNeeded()

        XCTAssertEqual(factory.openCount, 0)
        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertEqual(
            store.transientError,
            "The saved relay profile is invalid. Open Configure Relay and save it again."
        )
    }

    @MainActor
    func testAutoConnectDoesNotAttemptWithoutAStoredToken() async throws {
        let profileURL = temporaryProfileURL()
        defer { try? FileManager.default.removeItem(at: profileURL.deletingLastPathComponent()) }

        let configuration = RelayConfigurationStore(
            secureStore: AutoConnectSecureValueStore(),
            profileURL: profileURL
        )
        let profile = try RelayProfile(
            endpoint: URL(string: "wss://relay.example.test/session")!,
            clientID: "hermes-ios",
            deviceID: "device-123",
            displayName: "Test iPhone"
        )
        try await configuration.saveProfile(profile)

        let factory = AutoConnectWebSocketConnectionFactory(socket: AutoConnectWebSocketConnection())
        let store = ConversationStore(
            configurationStore: configuration,
            socketFactory: factory
        )

        await store.autoConnectIfNeeded()

        XCTAssertEqual(factory.openCount, 0)
        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertEqual(store.transientError, "Add a Hermes relay token before connecting.")
    }

    @MainActor
    func testAutoConnectFailureExposesRetryableConnectionState() async throws {
        let profileURL = temporaryProfileURL()
        defer { try? FileManager.default.removeItem(at: profileURL.deletingLastPathComponent()) }

        let configuration = RelayConfigurationStore(
            secureStore: AutoConnectSecureValueStore(),
            profileURL: profileURL
        )
        let profile = try RelayProfile(
            endpoint: URL(string: "wss://relay.example.test/session")!,
            clientID: "hermes-ios",
            deviceID: "device-123",
            displayName: "Test iPhone"
        )
        try await configuration.saveProfile(profile)
        try await configuration.saveToken("test-token", for: profile.id)

        let socket = AutoConnectWebSocketConnection(frames: [
            .text("{\"type\":\"status\",\"text\":\"not an ack\"}")
        ])
        let factory = AutoConnectWebSocketConnectionFactory(socket: socket)
        let store = ConversationStore(
            configurationStore: configuration,
            socketFactory: factory
        )

        await store.autoConnectIfNeeded()

        XCTAssertEqual(factory.openCount, 1)
        XCTAssertEqual(
            store.connectionState,
            .failed("The Hermes relay did not acknowledge the session.")
        )
        XCTAssertEqual(
            store.transientError,
            "The Hermes relay did not acknowledge the session."
        )
    }

    @MainActor
    func testHomeKnownRejectionAllowsAFreshPrompt() async throws {
        let fixture = try await makeHomeReviewFixture()
        defer { try? FileManager.default.removeItem(at: fixture.profileURL.deletingLastPathComponent()) }
        await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        await fixture.client.setNextSubmissionOutcome(
            .rejected(.home(code: .requestRejected, phase: .submission))
        )

        let rejected = await fixture.store.sendTurn(text: "known rejection")

        XCTAssertFalse(rejected)
        XCTAssertEqual(
            fixture.store.homeTurnDeliveryState,
            .failedKnown(.home(code: .requestRejected, phase: .submission))
        )

        let freshTurn = Task { @MainActor in
            await fixture.store.sendTurn(text: "fresh action")
        }
        await waitForHomeSubmissionCount(fixture.client, atLeast: 2)
        let scope = HomeEventScope(
            conversationHandle: fixture.claim.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        await fixture.client.emit(.standard(HomeStandardEvent(
            type: .turnComplete,
            scope: scope,
            payload: .terminal(kind: .terminal)
        )))

        let freshCompleted = await freshTurn.value
        XCTAssertTrue(freshCompleted)
        let submittedTexts = await fixture.client.submittedTexts
        XCTAssertEqual(submittedTexts, ["known rejection", "fresh action"])
        XCTAssertEqual(fixture.store.homeTurnDeliveryState, .idle)
    }

    @MainActor
    func testHomeAudioFailurePreservesReadableResponseText() async throws {
        let fixture = try await makeHomeReviewFixture()
        defer { try? FileManager.default.removeItem(at: fixture.profileURL.deletingLastPathComponent()) }
        await fixture.store.loadConfiguredClient()
        await fixture.store.connect()

        let sendTask = Task { @MainActor in
            await fixture.store.sendTurn(
                text: "voice prompt",
                eventHandler: { _ in }
            )
        }
        await waitForHomeSubmissionCount(fixture.client, atLeast: 1)
        let scope = HomeEventScope(
            conversationHandle: fixture.claim.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        await fixture.client.emit(.audioTerminal(scope, .invalid))
        await fixture.client.emit(.standard(HomeStandardEvent(
            type: .messageComplete,
            scope: scope,
            payload: .final(
                rendered: "text survives audio failure",
                text: nil,
                status: "completed",
                reasoning: nil,
                failureReason: nil
            )
        )))
        await fixture.client.emit(.standard(HomeStandardEvent(
            type: .turnComplete,
            scope: scope,
            payload: .terminal(kind: .terminal)
        )))

        let sendCompleted = await sendTask.value
        XCTAssertTrue(sendCompleted)
        XCTAssertEqual(fixture.store.messages.last?.text, "text survives audio failure")
        XCTAssertEqual(fixture.store.homeAudioState, .invalid(generation: 1))
    }

    @MainActor
    func testHomeTurnEventsUseTurnIDWhenEventCorrelationDiffers() async throws {
        let fixture = try await makeHomeReviewFixture()
        defer { try? FileManager.default.removeItem(at: fixture.profileURL.deletingLastPathComponent()) }
        await fixture.store.loadConfiguredClient()
        await fixture.store.connect()

        let sendTask = Task { @MainActor in
            await fixture.store.sendTurn(
                text: "correlation scope check",
                eventHandler: { _ in }
            )
        }
        await waitForHomeSubmissionCount(fixture.client, atLeast: 1)
        let audioScope = HomeEventScope(
            conversationHandle: fixture.claim.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        let standardEventScope = HomeEventScope(
            conversationHandle: fixture.claim.conversationHandle,
            turnID: "turn-1",
            correlationID: "standard-event-correlation"
        )
        await fixture.client.emit(.audioTerminal(audioScope, .end))
        await fixture.client.emit(.standard(HomeStandardEvent(
            type: .messageComplete,
            scope: standardEventScope,
            payload: .final(
                rendered: "The turn correlation is independent.",
                text: nil,
                status: "completed",
                reasoning: nil,
                failureReason: nil
            )
        )))
        await fixture.client.emit(.standard(HomeStandardEvent(
            type: .turnComplete,
            scope: standardEventScope,
            payload: .terminal(kind: .terminal)
        )))

        let sendCompleted = await sendTask.value
        XCTAssertTrue(sendCompleted)
        XCTAssertEqual(fixture.store.messages.last?.text, "The turn correlation is independent.")
    }

    @MainActor
    func testHomeInterruptWaitsForMatchingTerminal() async throws {
        let fixture = try await makeHomeReviewFixture()
        defer { try? FileManager.default.removeItem(at: fixture.profileURL.deletingLastPathComponent()) }
        await fixture.store.loadConfiguredClient()
        await fixture.store.connect()

        let sendTask = Task { @MainActor in
            await fixture.store.sendTurn(
                text: "interruptible Home prompt",
                eventHandler: { _ in }
            )
        }
        await waitForHomeSubmissionCount(fixture.client, atLeast: 1)
        var acceptedTurn: HomeTurnBinding?
        for _ in 0..<100 {
            if case .accepted(let turn) = fixture.store.homeTurnDeliveryState {
                acceptedTurn = turn
                break
            }
            await Task.yield()
        }
        XCTAssertNotNil(acceptedTurn)
        guard let acceptedTurn else {
            sendTask.cancel()
            _ = await sendTask.value
            return
        }
        let resultRecorder = HomeInterruptResultRecorder()
        let interruptTask = Task { @MainActor in
            let result = await fixture.store.interruptActiveTurn()
            await resultRecorder.record(result)
            return result
        }
        for _ in 0..<100 {
            if (await fixture.client.interruptTurnIDs).count == 1 { break }
            await Task.yield()
        }

        let resultBeforeTerminal = await resultRecorder.value()
        XCTAssertNil(resultBeforeTerminal)
        await fixture.client.emit(.standard(HomeStandardEvent(
            type: .turnInterrupted,
            scope: HomeEventScope(
                conversationHandle: acceptedTurn.conversationHandle,
                turnID: "stale-turn",
                correlationID: acceptedTurn.correlationID
            ),
            payload: .terminal(kind: .terminal)
        )))
        for _ in 0..<100 { await Task.yield() }
        let resultAfterStaleTerminal = await resultRecorder.value()
        XCTAssertNil(resultAfterStaleTerminal)

        let scope = HomeEventScope(
            conversationHandle: acceptedTurn.conversationHandle,
            turnID: acceptedTurn.turnID,
            correlationID: acceptedTurn.correlationID
        )
        await fixture.client.emit(.standard(HomeStandardEvent(
            type: .turnInterrupted,
            scope: scope,
            payload: .terminal(kind: .terminal)
        )))

        let didInterrupt = await interruptTask.value
        let sendCompleted = await sendTask.value
        XCTAssertTrue(didInterrupt)
        XCTAssertFalse(sendCompleted)
        XCTAssertEqual(fixture.store.homeTurnDeliveryState, .idle)
        XCTAssertNil(fixture.store.unconfirmedTurnText)
    }

    private func temporaryProfileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesRelayIOS-AutoConnect-\(UUID().uuidString)")
            .appendingPathComponent("profile.json")
    }

    @MainActor
    private func makeHomeReviewFixture() async throws -> HomeStoreReviewFixture {
        let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let profile = try RelayProfile(
            id: profileID,
            endpoint: URL(string: "wss://legacy.example/session")!,
            clientID: "hermes-apple",
            deviceID: "apple-device",
            displayName: "Test Apple"
        )
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesRelayIOS-HomeReview-\(UUID().uuidString)")
            .appendingPathExtension("json")
        let configurationStore = RelayConfigurationStore(
            secureStore: HomeStoreReviewSecureValueStore(),
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
        let store = ConversationStore(
            configurationStore: configurationStore,
            homeClientFactory: FakeHomeBridgeSessionClientFactory(client: client),
            homeClaimProvider: StaticHomeConversationClaimProvider(claim: claim)
        )
        return HomeStoreReviewFixture(
            store: store,
            client: client,
            claim: claim,
            profileURL: profileURL
        )
    }

    @MainActor
    private func waitForHomeSubmissionCount(
        _ client: FakeHomeBridgeSessionClient,
        atLeast count: Int
    ) async {
        for _ in 0..<100 {
            if (await client.submittedTexts).count >= count { return }
            await Task.yield()
        }
        XCTFail("The Home fake did not receive \(count) submissions")
    }
}

@MainActor
private struct HomeStoreReviewFixture {
    let store: ConversationStore
    let client: FakeHomeBridgeSessionClient
    let claim: HomeConversationClaim
    let profileURL: URL
}

private final class HomeStoreReviewSecureValueStore: SecureValueStore, @unchecked Sendable {
    func read(service: String, account: String) throws -> Data? { nil }
    func write(_ value: Data, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}

private actor HomeInterruptResultRecorder {
    private var recorded: Bool?

    func record(_ result: Bool) {
        recorded = result
    }

    func value() -> Bool? {
        recorded
    }
}

private enum FakeClientError: LocalizedError, Sendable {
    case offline

    var errorDescription: String? {
        "The test relay is offline."
    }
}

private final class FakeHermesSessionClient: HermesSessionClient, @unchecked Sendable {
    var connectResult: Result<SessionMetadata, Error> = .success(
        SessionMetadata(sessionID: "session-1", model: nil)
    )
    var eventsByText: [String: [HermesEvent]] = [:]
    var sendError: Error?
    private(set) var sentTurns: [String] = []

    func connect() async throws -> SessionMetadata {
        try connectResult.get()
    }

    func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error> {
        sentTurns.append(text)
        if let sendError {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: sendError)
            }
        }
        let events = eventsByText[text] ?? [.turnComplete(turnID: "turn-1")]
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func disconnect() async {}
}

private actor InterruptibleHermesSessionClient: HermesSessionClient {
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private var turnContinuation: AsyncThrowingStream<HermesEvent, Error>.Continuation?
    private var turnStarted = false
    private var turnStartWaiters: [CheckedContinuation<Void, Never>] = []

    func connect() async throws -> SessionMetadata {
        connectCount += 1
        return SessionMetadata(sessionID: "session-\(connectCount)", model: nil)
    }

    func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<HermesEvent, Error>.makeStream()
        turnContinuation = continuation
        turnStarted = true
        turnStartWaiters.forEach { $0.resume() }
        turnStartWaiters.removeAll()
        continuation.yield(.status(text: "Working", kind: "test"))
        return stream
    }

    func disconnect() async {
        disconnectCount += 1
        turnContinuation?.yield(.messageStart)
        turnContinuation?.yield(.textDelta("late response"))
        turnContinuation?.finish(throwing: RelaySessionError.disconnected)
        turnContinuation = nil
    }

    func waitUntilTurnStarted() async {
        if turnStarted { return }
        await withCheckedContinuation { continuation in
            turnStartWaiters.append(continuation)
        }
    }
}

private actor ServerInterruptHermesSessionClient: HermesSessionClient {
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var interruptCount = 0
    private var turnContinuation: AsyncThrowingStream<HermesEvent, Error>.Continuation?
    private var turnStarted = false
    private var turnStartWaiters: [CheckedContinuation<Void, Never>] = []

    func connect() async throws -> SessionMetadata {
        connectCount += 1
        return SessionMetadata(
            sessionID: "session-\(connectCount)",
            model: nil,
            capabilities: ["interrupt"]
        )
    }

    func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<HermesEvent, Error>.makeStream()
        turnContinuation = continuation
        turnStarted = true
        turnStartWaiters.forEach { $0.resume() }
        turnStartWaiters.removeAll()
        continuation.yield(.messageStart)
        continuation.yield(.textDelta("partial answer"))
        return stream
    }

    func interruptActiveTurn() async -> Bool {
        interruptCount += 1
        turnContinuation?.yield(.audioAbort(turnID: "turn-1", reason: "client interrupt"))
        turnContinuation?.yield(.turnInterrupted(turnID: "turn-1", reason: "turn interrupted"))
        turnContinuation?.finish()
        turnContinuation = nil
        return true
    }

    func disconnect() async {
        disconnectCount += 1
        turnContinuation?.finish(throwing: RelaySessionError.disconnected)
        turnContinuation = nil
    }

    func waitUntilTurnStarted() async {
        if turnStarted { return }
        await withCheckedContinuation { continuation in
            turnStartWaiters.append(continuation)
        }
    }
}

private actor DraftRecordingPersistence: ConversationPersistence {
    private var savedConversation: PersistedConversation?

    func load() async throws -> PersistedConversation {
        savedConversation ?? PersistedConversation(messages: [], draft: "")
    }

    func save(_ conversation: PersistedConversation) async throws {
        savedConversation = conversation
    }

    func lastSaved() -> PersistedConversation? {
        savedConversation
    }
}

private final class AutoConnectSecureValueStore: SecureValueStore, @unchecked Sendable {
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

private final class AutoConnectWebSocketConnectionFactory: WebSocketConnectionFactory, @unchecked Sendable {
    let socket: AutoConnectWebSocketConnection
    private(set) var openCount = 0
    private(set) var lastRequest: URLRequest?
    private(set) var openedSockets: [AutoConnectWebSocketConnection] = []
    /// Each connection needs its own socket: a socket's queued hello_ack is
    /// consumed by the first handshake, so reusing one would park the second
    /// connection forever rather than failing.
    private let makeSocket: (@Sendable () -> AutoConnectWebSocketConnection)?

    init(
        socket: AutoConnectWebSocketConnection,
        makeSocket: (@Sendable () -> AutoConnectWebSocketConnection)? = nil
    ) {
        self.socket = socket
        self.makeSocket = makeSocket
    }

    func open(urlRequest: URLRequest) async throws -> any WebSocketConnection {
        openCount += 1
        lastRequest = urlRequest
        let connection = makeSocket?() ?? socket
        openedSockets.append(connection)
        return connection
    }
}

private final class AutoConnectWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let stateLock = NSLock()
    private var queuedFrames: [WebSocketFrame]
    private var pendingReceive: CheckedContinuation<WebSocketFrame, Error>?
    private(set) var sentTexts: [String] = []

    init(frames: [WebSocketFrame] = [
        .text("{\"type\":\"hello_ack\",\"model\":\"test-model\"}")
    ]) {
        queuedFrames = frames
    }

    func send(text: String) async throws {
        appendSentText(text)
    }

    func receive() async throws -> WebSocketFrame {
        try await withCheckedThrowingContinuation { continuation in
            receive(using: continuation)
        }
    }

    func close() async {
        let continuation = removePendingReceive()
        continuation?.resume(throwing: RelaySessionError.disconnected)
    }

    private func appendSentText(_ text: String) {
        stateLock.lock()
        sentTexts.append(text)
        stateLock.unlock()
    }

    private func receive(using continuation: CheckedContinuation<WebSocketFrame, Error>) {
        stateLock.lock()
        if !queuedFrames.isEmpty {
            let frame = queuedFrames.removeFirst()
            stateLock.unlock()
            continuation.resume(returning: frame)
        } else {
            pendingReceive = continuation
            stateLock.unlock()
        }
    }

    private func removePendingReceive() -> CheckedContinuation<WebSocketFrame, Error>? {
        stateLock.lock()
        let continuation = pendingReceive
        pendingReceive = nil
        stateLock.unlock()
        return continuation
    }
}
