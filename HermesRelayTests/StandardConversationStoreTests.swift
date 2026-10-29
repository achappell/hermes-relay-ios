import Foundation
import XCTest
@testable import HermesRelayIOS

final class StandardConversationStoreTests: XCTestCase {
    @MainActor
    func testDirectRoutingReadsOnlyStandardCredentialAndStreamsTypedText() async throws {
        let fixture = try await makeFixture()
        await fixture.client.setEvents([.messageStart, .textDelta("Hello "), .textDelta("Apple"), .turnComplete(turnID: "one")])
        let configured = await fixture.store.loadConfiguredClient()
        XCTAssertTrue(configured)
        await fixture.store.connect()
        XCTAssertTrue(fixture.store.isStandardMode)
        XCTAssertNil(fixture.store.sessionMetadata?.sessionID)
        XCTAssertEqual(fixture.store.verifiedTurnBinding?.identity, .standard(sessionID: "runtime-original", storedSessionID: "durable-original"))

        fixture.store.draft = "Hello"
        let completed = await fixture.store.sendDraft()
        let beforeSubmission = await fixture.client.recoveryAtSubmission
        let saved = try await fixture.persistence.load()
        let sent = await fixture.client.sentTurns
        XCTAssertTrue(completed)
        XCTAssertEqual(sent, ["Hello"])
        XCTAssertEqual(beforeSubmission?.unconfirmedTurnText, "Hello")
        XCTAssertEqual(beforeSubmission?.standardSessionID, "durable-original")
        XCTAssertEqual(fixture.store.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(fixture.store.messages.last?.text, "Hello Apple")
        XCTAssertNil(saved.unconfirmedTurnText)
        XCTAssertEqual(saved.standardSessionID, "durable-original")
        XCTAssertEqual(Set(fixture.secure.readServices), [RelayConfigurationStore.standardKeychainService])
    }

    @MainActor
    func testMissingStandardTokenNeverUsesLegacyToken() async throws {
        let fixture = try await makeFixture(saveStandardToken: false)
        let configured = await fixture.store.loadConfiguredClient()
        XCTAssertFalse(configured)
        XCTAssertEqual(fixture.factory.calls.count, 0)
        XCTAssertNotNil(fixture.store.transientError)
        XCTAssertEqual(Set(fixture.secure.readServices), [RelayConfigurationStore.standardKeychainService])
    }

    @MainActor
    func testDroppedTurnReconnectsWithoutReplayAndKeepsUncertainty() async throws {
        let fixture = try await makeFixture()
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        let turn = Task { await fixture.store.sendTurn(text: "only once") }
        await fixture.client.waitForSubmission()
        await fixture.client.drop()
        fixture.store.handleUnexpectedTransportLoss()
        let completed = await turn.value
        await fixture.store.waitForReconnectToFinish()
        let retry = await fixture.store.sendTurn(text: "only once")
        let sent = await fixture.client.sentTurns
        let connects = await fixture.client.connectCount
        let saved = try await fixture.persistence.load()
        XCTAssertFalse(completed)
        XCTAssertFalse(retry)
        XCTAssertEqual(sent, ["only once"])
        XCTAssertEqual(connects, 2)
        XCTAssertTrue(fixture.store.connectionState.isConnected)
        XCTAssertEqual(saved.unconfirmedTurnText, "only once")
        XCTAssertNotNil(fixture.store.connectionChangeBlockedReason)
    }

    @MainActor
    func testRelaunchRetainsUncertaintyWithoutResendingHistory() async throws {
        let history = PersistedConversation(messages: [TranscriptMessage(role: .user, text: "earlier")], draft: "", unconfirmedTurnText: "earlier", standardSessionID: "durable-original")
        let fixture = try await makeFixture(history: history)
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.loadPersistedConversation()
        await fixture.store.connect()
        XCTAssertEqual(fixture.store.unconfirmedTurnText, "earlier")
        let sent = await fixture.client.sentTurns
        XCTAssertTrue(sent.isEmpty)
        XCTAssertFalse(fixture.store.standardNeedsNewConversation)
        XCTAssertNotNil(fixture.store.connectionChangeBlockedReason)
    }

    @MainActor
    func testHistoryWithoutDurableReferenceRequiresDeliberateNew() async throws {
        let history = PersistedConversation(messages: [TranscriptMessage(role: .user, text: "old transcript")], draft: "")
        let fixture = try await makeFixture(history: history)
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        let initialConnects = await fixture.client.connectCount
        XCTAssertEqual(initialConnects, 0, "No silent fresh session may appear beneath old history")
        XCTAssertTrue(fixture.store.standardNeedsNewConversation)
        XCTAssertTrue(fixture.store.transientError?.contains("not resent") == true)
        await fixture.store.startNewStandardConversation()
        let saved = try await fixture.persistence.load()
        XCTAssertFalse(fixture.store.standardNeedsNewConversation)
        XCTAssertNil(fixture.store.connectionChangeBlockedReason)
        XCTAssertEqual(fixture.store.messages.map(\.text), ["old transcript", ConversationStore.newHomeConversationDividerText])
        XCTAssertEqual(saved.standardSessionID, "durable-new")
        let sent = await fixture.client.sentTurns
        XCTAssertTrue(sent.isEmpty)
    }

    @MainActor
    func testFailedResumeAndFailedNewRetainRecoveryUntilLocalLeave() async throws {
        let history = PersistedConversation(messages: [TranscriptMessage(role: .user, text: "uncertain")], draft: "staged", unconfirmedTurnText: "uncertain", standardSessionID: "durable-original")
        let fixture = try await makeFixture(history: history)
        await fixture.client.setConnectFailure(.resumeFailed)
        await fixture.client.setNewFailure(.connectionFailed)
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        XCTAssertTrue(fixture.store.standardNeedsNewConversation)
        await fixture.store.startNewStandardConversation()
        XCTAssertEqual(fixture.store.unconfirmedTurnText, "uncertain")
        XCTAssertNotNil(fixture.store.connectionChangeBlockedReason)
        let failedNew = try await fixture.persistence.load()
        XCTAssertNil(failedNew.standardSessionID)
        XCTAssertEqual(failedNew.standardNeedsNewConversation, true)
        await fixture.store.leaveCurrentConversation()
        let saved = try await fixture.persistence.load()
        let leaves = await fixture.client.leaveCount
        let interrupts = await fixture.client.interruptCount
        XCTAssertEqual(leaves, 1)
        XCTAssertEqual(interrupts, 0)
        XCTAssertNil(fixture.store.connectionChangeBlockedReason)
        XCTAssertNil(saved.unconfirmedTurnText)
        XCTAssertNil(saved.standardSessionID)
        XCTAssertEqual(saved.messages, history.messages)
        XCTAssertEqual(fixture.store.draft, "staged")
        XCTAssertTrue(fixture.store.standardNeedsNewConversation)
    }

    @MainActor
    func testUnsupportedStopKeepsSameStreamUntilRemoteTerminal() async throws {
        let fixture = try await makeFixture()
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        let turn = Task { await fixture.store.sendTurn(text: "working") }
        await fixture.client.waitForSubmission()
        let stopped = await fixture.store.interruptActiveTurn()
        let second = await fixture.store.sendTurn(text: "must not queue")
        let disconnects = await fixture.client.disconnectCount
        XCTAssertFalse(stopped)
        XCTAssertFalse(second)
        XCTAssertEqual(disconnects, 0, "Standard must not use the Legacy close/reconnect fallback")
        XCTAssertTrue(fixture.store.isSending)
        XCTAssertTrue(fixture.store.connectionChangeBlockedReason?.contains("finishing") == true)
        await fixture.client.finishTurn()
        let completed = await turn.value
        XCTAssertTrue(completed)
        XCTAssertNil(fixture.store.connectionChangeBlockedReason)
        XCTAssertNil(fixture.store.unconfirmedTurnText)
    }

    @MainActor
    func testUnsupportedInteractionIsVisibleAndCannotBecomeAChatReply() async throws {
        let fixture = try await makeFixture()
        await fixture.client.setSendFailure(.unsupportedInteraction)
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        let completed = await fixture.store.sendTurn(text: "requires approval")
        XCTAssertFalse(completed)
        XCTAssertEqual(fixture.store.unconfirmedTurnText, "requires approval")
        XCTAssertTrue(fixture.store.connectionChangeBlockedReason?.contains("finishing") == true)
        XCTAssertNotNil(fixture.store.transientError)
        XCTAssertNil(fixture.store.pendingHomePrompt)
        XCTAssertFalse(fixture.store.messages.contains(where: { $0.role == .assistant }))
    }

    @MainActor
    func testActiveAndUncertainReconfigurationGuardsPreserveDraftAndTranscript() async throws {
        let fixture = try await makeFixture()
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        let turn = Task { await fixture.store.sendTurn(text: "owned by original") }
        await fixture.client.waitForSubmission()
        fixture.store.draft = "unsent draft"
        let originalProfile = fixture.store.activeProfileID
        let originalMessages = fixture.store.messages
        await fixture.store.clearSelectedProfile()
        await fixture.store.switchToSelectedProfile()
        XCTAssertEqual(fixture.store.activeProfileID, originalProfile)
        XCTAssertEqual(fixture.store.messages, originalMessages)
        XCTAssertEqual(fixture.store.draft, "unsent draft")
        await fixture.client.drop()
        _ = await turn.value
        await fixture.store.clearSelectedProfile()
        XCTAssertEqual(fixture.store.activeProfileID, originalProfile)
        await fixture.store.leaveCurrentConversation()
        await fixture.store.clearSelectedProfile()
        XCTAssertNil(fixture.store.activeProfileID)
    }

    @MainActor
    func testLegacyActiveAndUncertainTurnsAlsoBlockReconfigurationUntilLeave() async {
        let client = StoreStandardClient(metadata: SessionMetadata(sessionID: "legacy", model: nil))
        let store = ConversationStore(client: client)
        await store.connect()
        let turn = Task { await store.sendTurn(text: "legacy work") }
        await client.waitForSubmission()
        store.draft = "keep me"
        await store.clearSelectedProfile()
        XCTAssertTrue(store.isSending)
        XCTAssertEqual(store.draft, "keep me")
        await client.drop()
        _ = await turn.value
        XCTAssertNotNil(store.connectionChangeBlockedReason)
        await store.leaveCurrentConversation()
        XCTAssertNil(store.connectionChangeBlockedReason)
        XCTAssertTrue(store.messages.contains(where: { $0.text == "legacy work" }))
    }

    @MainActor
    func testStandardBackgroundClosesTransportPreservesRecoveryAndNeverRetainsVoice() async throws {
        let fixture = try await makeFixture()
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        let input = StoreStandardSpeechInput()
        let handsFree = StoreStandardHandsFreeInput()
        let voice = VoiceSessionCoordinator(store: fixture.store, input: input, output: StoreStandardAudioOutput(), handsFreeInput: handsFree)
        await voice.beginCapture()
        await voice.toggleHandsFree()
        let starts = await input.starts
        let handsFreeRequests = await handsFree.authorizationRequests
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(handsFreeRequests, 0)
        XCTAssertFalse(voice.isHandsFreeArmed)
        XCTAssertNotNil(fixture.store.standardVoiceUnavailableReason)
        let turn = Task { await fixture.store.sendTurn(text: "background turn") }
        await fixture.client.waitForSubmission()
        XCTAssertEqual(voice.backgroundRetention, .none)
        let lifecycle = AppleLifecycleCoordinator(store: fixture.store, voice: voice, homeClientFactory: UnavailableHomeBridgeSessionClientFactory(), clock: ContinuousHomeMonotonicClock(), backgroundRetentionEnabled: true)
        let result = await lifecycle.handle(.background)
        _ = await turn.value
        let saved = try await fixture.persistence.load()
        let disconnects = await fixture.client.disconnectCount
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(disconnects, 1)
        XCTAssertEqual(fixture.store.connectionState, .disconnected)
        XCTAssertEqual(saved.unconfirmedTurnText, "background turn")
        XCTAssertFalse(lifecycle.isRetainingBackgroundWork)
        let foreground = await lifecycle.handle(.active)
        XCTAssertEqual(foreground, .completed)
        let sent = await fixture.client.sentTurns
        XCTAssertEqual(sent, ["background turn"])
        XCTAssertEqual(fixture.store.unconfirmedTurnText, "background turn")
    }

    @MainActor
    func testSuccessfulNewRetiresAnActiveStreamAndClearsOnlyItsRecovery() async throws {
        let fixture = try await makeFixture()
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        let oldTurn = Task { await fixture.store.sendTurn(text: "leave this work behind") }
        await fixture.client.waitForSubmission()
        await fixture.store.startNewStandardConversation()
        let completed = await oldTurn.value
        let saved = try await fixture.persistence.load()
        XCTAssertFalse(completed)
        XCTAssertNil(fixture.store.unconfirmedTurnText)
        XCTAssertNil(fixture.store.connectionChangeBlockedReason)
        XCTAssertEqual(saved.standardSessionID, "durable-new")
        XCTAssertEqual(saved.messages.map(\.text), ["leave this work behind", ConversationStore.newHomeConversationDividerText])
        XCTAssertTrue(fixture.store.connectionState.isConnected)
    }

    @MainActor
    func testConsumerProfileSwitchLoadsSeparateStandardHistoryAndDurableReference() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StandardHistory-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let configuration = RelayConfigurationStore(secureStore: StoreStandardSecureStore(), profileURL: directory.appendingPathComponent("profiles.json"))
        let first = try RelayProfile(endpoint: URL(string: "wss://first.example/api/ws")!, clientID: "", deviceID: "", displayName: "First", standardProfile: "default")
        let second = try RelayProfile(endpoint: URL(string: "wss://second.example/api/ws")!, clientID: "", deviceID: "", displayName: "Second", standardProfile: "other")
        try await configuration.saveCollection(RelayProfileCollection(profiles: [first, second], selectedID: first.id))
        try await configuration.saveStandardToken("first-token", for: first.id)
        try await configuration.saveStandardToken("second-token", for: second.id)
        let client = StoreStandardClient()
        await client.setEvents([.textDelta("first reply"), .turnComplete(turnID: "first")])
        let factory = StoreStandardFactory(client: client)
        let store = ConversationStore(configurationStore: configuration, makeProfilePersistence: { profile in
            JSONConversationPersistence(fileURL: ConversationPersistenceFile.url(in: directory, for: profile))
        }, standardClientFactory: { profile, token, storedSessionID in
            factory.make(profile: profile, token: token, storedSessionID: storedSessionID)
        })
        _ = await store.loadConfiguredClient()
        await store.connect()
        _ = await store.sendTurn(text: "first connection only")
        try await configuration.selectProfile(id: second.id)
        await store.switchToSelectedProfile()
        XCTAssertEqual(store.activeProfileID, second.id)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNil(factory.calls.last?.storedSessionID)
        XCTAssertEqual(factory.calls.last?.token, "second-token")
        try await configuration.selectProfile(id: first.id)
        await store.switchToSelectedProfile()
        XCTAssertEqual(store.messages.map(\.text), ["first connection only", "first reply"])
        let sent = await client.sentTurns
        XCTAssertEqual(sent, ["first connection only"])
    }

    @MainActor
    func testHomeUncertaintyAlsoBlocksChangesAndLocalLeaveKeepsHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StandardHomeGuard-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let profile = try RelayProfile(endpoint: URL(string: "wss://legacy.example/session")!, clientID: "apple", deviceID: "device", displayName: "Home")
        let claim = HomeDemoFixtures.claim(for: profile.id)
        let configuration = RelayConfigurationStore(secureStore: StoreStandardSecureStore(), profileURL: directory.appendingPathComponent("profiles.json"))
        let migration = HomeMigrationJournal(schemaVersion: 1, profileID: profile.id, phase: .homeSelected, selectedMode: .home, credential: nil, legacyCredentialRetained: true, updatedAt: Date())
        try await configuration.saveCollection(RelayProfileCollection(profiles: [profile], selectedID: profile.id, homeMigrations: [profile.id: migration]))
        let recovery = PersistedHomeRecovery(profileID: profile.id, endpoint: claim.approvedRoute.endpoint, route: claim.approvedRoute.identity, householdBinding: claim.approvedRoute.householdBinding, conversationHandle: claim.conversationHandle, turnID: "uncertain", correlationID: nil, submissionAttemptID: nil, resumeCursor: nil, deliveryState: .uncertain, updatedAt: Date())
        let history = PersistedConversation(messages: [TranscriptMessage(role: .user, text: "Home uncertain")], draft: "Home draft", unconfirmedTurnText: "Home uncertain", homeRecovery: recovery)
        let store = ConversationStore(configurationStore: configuration, persistence: StoreStandardPersistence(history), homeClaimProvider: StaticHomeConversationClaimProvider(claim: claim))
        _ = await store.loadConfiguredClient()
        await store.loadPersistedConversation()
        XCTAssertTrue(store.isHomeMode)
        await store.clearSelectedProfile()
        XCTAssertEqual(store.activeProfileID, profile.id)
        XCTAssertNotNil(store.connectionChangeBlockedReason)
        await store.leaveCurrentConversation()
        XCTAssertNil(store.connectionChangeBlockedReason)
        XCTAssertEqual(store.messages, history.messages)
        XCTAssertEqual(store.draft, "Home draft")
    }

    @MainActor
    func testRecoveryMustBeSavedBeforeAnyStandardSubmission() async throws {
        let fixture = try await makeFixture()
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        await fixture.persistence.setSaveFailure(true)
        let completed = await fixture.store.sendTurn(text: "do not submit without recovery")
        let sent = await fixture.client.sentTurns
        XCTAssertFalse(completed)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(fixture.store.transientError?.contains("not submitted") == true)
    }

    @MainActor
    func testUnderlyingErrorsCannotExposeAuthenticatedURLInHistoryOrPresentation() async throws {
        let fixture = try await makeFixture()
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        await fixture.client.setUnsafeFailure()
        _ = await fixture.store.sendTurn(text: "safe prompt")
        let persisted = try await fixture.persistence.load()
        let encoded = String(decoding: try JSONEncoder().encode(persisted), as: UTF8.self)
        let visible = fixture.store.messages.map(\.text).joined() + (fixture.store.transientError ?? "")
        XCTAssertFalse(encoded.contains("sentinel-secret"))
        XCTAssertFalse(visible.contains("sentinel-secret"))
        XCTAssertFalse(visible.contains("wss://"))
    }

    @MainActor
    func testLeavingAnEmptySessionStillRequiresNewAfterRestoration() async throws {
        let fixture = try await makeFixture()
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        await fixture.store.leaveCurrentConversation()
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        let connects = await fixture.client.connectCount
        XCTAssertEqual(connects, 1)
        XCTAssertTrue(fixture.store.standardNeedsNewConversation)
        XCTAssertNil(fixture.store.connectionChangeBlockedReason)
        let sent = await fixture.client.sentTurns
        XCTAssertTrue(sent.isEmpty)
    }

    @MainActor
    func testNewDoesNotRequestReplacementWhenInvalidationCannotBeSaved() async throws {
        let fixture = try await makeFixture()
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        await fixture.persistence.setSaveFailure(true)

        await fixture.store.startNewStandardConversation()
        let attemptedReplacement = await fixture.client.recoveryAtReplacement
        XCTAssertNil(attemptedReplacement)
        XCTAssertTrue(fixture.store.standardNeedsNewConversation)
        XCTAssertNil(fixture.store.verifiedTurnBinding)
        XCTAssertNotNil(fixture.store.connectionChangeBlockedReason)
        await fixture.store.loadPersistedConversation()
        await fixture.store.connect()
        let completed = await fixture.store.sendTurn(text: "never use the old session")
        let sent = await fixture.client.sentTurns
        XCTAssertFalse(completed)
        XCTAssertTrue(sent.isEmpty)

        await fixture.persistence.setSaveFailure(false)
        await fixture.store.startNewStandardConversation()
        XCTAssertNotNil(fixture.store.verifiedTurnBinding)
        XCTAssertNil(fixture.store.connectionChangeBlockedReason)
    }

    @MainActor
    func testFailedNewFromCertainEmptyConversationInvalidatesBindingBeforeReplacement() async throws {
        let fixture = try await makeFixture()
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        await fixture.client.setNewFailure(.connectionFailed)

        await fixture.store.startNewStandardConversation()
        let savedAtReplacement = await fixture.client.recoveryAtReplacement
        XCTAssertNil(savedAtReplacement?.standardSessionID)
        XCTAssertEqual(savedAtReplacement?.standardNeedsNewConversation, true)
        XCTAssertTrue(fixture.store.standardNeedsNewConversation)
        XCTAssertNil(fixture.store.sessionMetadata)
        XCTAssertNil(fixture.store.verifiedTurnBinding)
        let completed = await fixture.store.sendTurn(text: "never send to the previous conversation")
        XCTAssertFalse(completed)
        let sent = await fixture.client.sentTurns
        XCTAssertTrue(sent.isEmpty)

        // Rebuilding the configured client must not resume the old durable ID.
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        let connects = await fixture.client.connectCount
        XCTAssertEqual(connects, 1)
        XCTAssertNil(fixture.factory.calls.last?.storedSessionID)
        XCTAssertTrue(fixture.store.standardNeedsNewConversation)
        await fixture.client.setNewFailure(nil)
        await fixture.store.startNewStandardConversation()
        XCTAssertNotNil(fixture.store.verifiedTurnBinding)
    }

    @MainActor
    func testFailedLeaveRetainsRecoveryAndBlocksResumeUntilDurableRetry() async throws {
        let fixture = try await makeFixture()
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        let turn = Task { await fixture.store.sendTurn(text: "uncertain work") }
        await fixture.client.waitForSubmission()
        await fixture.persistence.setSaveFailure(true)

        await fixture.store.leaveCurrentConversation()
        _ = await turn.value
        let saved = try await fixture.persistence.load()
        XCTAssertEqual(saved.standardSessionID, "durable-original")
        XCTAssertEqual(saved.unconfirmedTurnText, "uncertain work")
        XCTAssertEqual(fixture.store.unconfirmedTurnText, "uncertain work")
        XCTAssertNotNil(fixture.store.connectionChangeBlockedReason)
        XCTAssertNil(fixture.store.verifiedTurnBinding)
        XCTAssertTrue(fixture.store.transientError?.contains("could not be saved") == true)
        XCTAssertFalse(fixture.store.transientError?.contains("You left") == true)
        XCTAssertFalse(fixture.store.transientError?.contains("sentinel-secret") == true)
        await fixture.store.loadPersistedConversation()
        await fixture.store.connect()
        let connects = await fixture.client.connectCount
        XCTAssertEqual(connects, 1, "Failed Leave must not resume the stale durable session")
        XCTAssertFalse(fixture.store.beginConnectionReconfiguration())
        let nextTurn = await fixture.store.sendTurn(text: "blocked")
        XCTAssertFalse(nextTurn)

        await fixture.persistence.setSaveFailure(false)
        await fixture.store.leaveCurrentConversation()
        let cleared = try await fixture.persistence.load()
        XCTAssertNil(cleared.standardSessionID)
        XCTAssertNil(cleared.unconfirmedTurnText)
        XCTAssertNil(fixture.store.connectionChangeBlockedReason)
        XCTAssertTrue(fixture.store.transientError?.contains("You left") == true)
    }

    @MainActor
    func testBackgroundSnapshotFailureStillClosesStandardTransportAndKeepsWriteAheadRecovery() async throws {
        let fixture = try await makeFixture()
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        let turn = Task { await fixture.store.sendTurn(text: "written ahead") }
        await fixture.client.waitForSubmission()
        await fixture.persistence.setSaveFailure(true)
        let voice = VoiceSessionCoordinator(store: fixture.store, input: StoreStandardSpeechInput(), output: StoreStandardAudioOutput())
        let lifecycle = AppleLifecycleCoordinator(store: fixture.store, voice: voice, homeClientFactory: UnavailableHomeBridgeSessionClientFactory(), clock: ContinuousHomeMonotonicClock(), backgroundRetentionEnabled: true)

        let result = await lifecycle.handle(.background)
        _ = await turn.value
        let disconnects = await fixture.client.disconnectCount
        let saved = try await fixture.persistence.load()
        XCTAssertEqual(result, .persistenceFailed)
        XCTAssertEqual(disconnects, 1)
        XCTAssertFalse(fixture.store.isLifecycleActive)
        XCTAssertFalse(lifecycle.isRetainingBackgroundWork)
        XCTAssertEqual(fixture.store.connectionState, .disconnected)
        XCTAssertEqual(fixture.store.unconfirmedTurnText, "written ahead")
        XCTAssertEqual(saved.unconfirmedTurnText, "written ahead")
        XCTAssertNotNil(fixture.store.connectionChangeBlockedReason)
        XCTAssertNil(fixture.store.verifiedTurnBinding)
    }

    @MainActor
    func testConnectionLeaseBlocksStandardTypedSendWithoutBlockingOwnersProfileCommit() async throws {
        let fixture = try await makeFixture()
        _ = await fixture.store.loadConfiguredClient()
        await fixture.store.connect()
        fixture.store.draft = "preserve draft"
        XCTAssertTrue(fixture.store.beginConnectionReconfiguration())
        XCTAssertTrue(fixture.store.isReconfiguringConnection)
        XCTAssertNil(fixture.store.connectionChangeBlockedReason)
        XCTAssertFalse(fixture.store.beginConnectionReconfiguration())
        XCTAssertNil(fixture.store.verifiedTurnBinding)
        let completed = await fixture.store.sendDraft()
        XCTAssertFalse(completed)
        XCTAssertEqual(fixture.store.draft, "preserve draft")
        let sent = await fixture.client.sentTurns
        XCTAssertTrue(sent.isEmpty)
        await fixture.store.clearSelectedProfile()
        XCTAssertNil(fixture.store.activeProfileID)
        XCTAssertTrue(fixture.store.isReconfiguringConnection)
        fixture.store.endConnectionReconfiguration()
        XCTAssertFalse(fixture.store.isReconfiguringConnection)
    }

    @MainActor
    private func makeFixture(history: PersistedConversation = PersistedConversation(messages: [], draft: ""), saveStandardToken: Bool = true) async throws -> StoreStandardFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StandardStore-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let secure = StoreStandardSecureStore()
        let configuration = RelayConfigurationStore(secureStore: secure, profileURL: directory.appendingPathComponent("profiles.json"))
        let profile = try RelayProfile(endpoint: URL(string: "wss://standard.example/api/ws")!, clientID: "", deviceID: "", displayName: "Direct", standardProfile: "default")
        try await configuration.saveProfile(profile)
        try await configuration.saveToken("legacy-must-not-be-read", for: profile.id)
        if saveStandardToken { try await configuration.saveStandardToken("standard-only", for: profile.id) }
        let persistence = StoreStandardPersistence(history)
        let client = StoreStandardClient(persistence: persistence)
        let factory = StoreStandardFactory(client: client)
        let store = ConversationStore(configurationStore: configuration, persistence: persistence, sleep: { _ in }, standardClientFactory: { profile, token, storedSessionID in
            factory.make(profile: profile, token: token, storedSessionID: storedSessionID)
        })
        return StoreStandardFixture(store: store, client: client, factory: factory, persistence: persistence, secure: secure)
    }
}

@MainActor
private struct StoreStandardFixture {
    let store: ConversationStore
    let client: StoreStandardClient
    let factory: StoreStandardFactory
    let persistence: StoreStandardPersistence
    let secure: StoreStandardSecureStore
}

private actor StoreStandardPersistence: ConversationPersistence {
    private var conversation: PersistedConversation
    private var saveFails = false
    func setSaveFailure(_ fails: Bool) { saveFails = fails }
    init(_ conversation: PersistedConversation) { self.conversation = conversation }
    func load() async throws -> PersistedConversation { conversation }
    func save(_ conversation: PersistedConversation) async throws {
        if saveFails { throw StoreStandardUnsafeError() }
        self.conversation = conversation
    }
}

private actor StoreStandardClient: StandardConversationSessionClient {
    private var metadata: SessionMetadata
    private let persistence: StoreStandardPersistence?
    private var events: [HermesEvent]?
    private var connectFailure: StandardSessionError?
    private var newFailure: StandardSessionError?
    private var sendFailure: (any Error)?
    private var continuation: AsyncThrowingStream<HermesEvent, Error>.Continuation?
    private var submissionWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var sentTurns: [String] = []
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var leaveCount = 0
    private(set) var interruptCount = 0
    private(set) var recoveryAtSubmission: PersistedConversation?
    private(set) var recoveryAtReplacement: PersistedConversation?

    init(metadata: SessionMetadata = SessionMetadata(standardSessionID: "runtime-original", storedSessionID: "durable-original"), persistence: StoreStandardPersistence? = nil) {
        self.metadata = metadata
        self.persistence = persistence
    }
    func setEvents(_ events: [HermesEvent]) { self.events = events }
    func setConnectFailure(_ error: StandardSessionError) { connectFailure = error }
    func setNewFailure(_ error: StandardSessionError?) { newFailure = error }
    func setSendFailure(_ error: StandardSessionError) { sendFailure = error }
    func setUnsafeFailure() { sendFailure = StoreStandardUnsafeError() }
    func connect() async throws -> SessionMetadata {
        connectCount += 1
        if let connectFailure { throw connectFailure }
        return metadata
    }
    func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error> {
        recoveryAtSubmission = try? await persistence?.load()
        sentTurns.append(text)
        let (stream, continuation) = AsyncThrowingStream<HermesEvent, Error>.makeStream()
        self.continuation = continuation
        if let sendFailure { continuation.finish(throwing: sendFailure) }
        if let events {
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
        let waiters = submissionWaiters
        submissionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return stream
    }
    func waitForSubmission() async {
        guard sentTurns.isEmpty else { return }
        await withCheckedContinuation { submissionWaiters.append($0) }
    }
    func finishTurn() {
        continuation?.yield(.turnComplete(turnID: "terminal"))
        continuation?.finish()
        continuation = nil
    }
    func drop() {
        continuation?.finish(throwing: StandardSessionError.disconnected)
        continuation = nil
    }
    func interruptActiveTurnOutcome() async -> HermesInterruptOutcome {
        interruptCount += 1
        return .unavailable
    }
    func disconnect() async {
        disconnectCount += 1
        drop()
    }
    func createNewConversation() async throws -> SessionMetadata {
        recoveryAtReplacement = try? await persistence?.load()
        if let newFailure { throw newFailure }
        drop()
        metadata = SessionMetadata(standardSessionID: "runtime-new", storedSessionID: "durable-new")
        return metadata
    }
    func leaveConversation() async {
        leaveCount += 1
        drop()
    }
}

private final class StoreStandardFactory: @unchecked Sendable {
    struct Call: Sendable {
        let token: String
        let storedSessionID: String?
    }
    private let lock = NSLock()
    private let client: StoreStandardClient
    private var recorded: [Call] = []
    init(client: StoreStandardClient) { self.client = client }
    var calls: [Call] { lock.withLock { recorded } }
    func make(profile: RelayProfile, token: String, storedSessionID: String?) -> any StandardConversationSessionClient {
        lock.withLock { recorded.append(Call(token: token, storedSessionID: storedSessionID)) }
        return client
    }
}

private final class StoreStandardSecureStore: SecureValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var reads: [String] = []
    var readServices: [String] { lock.withLock { reads } }
    func read(service: String, account: String) throws -> Data? {
        lock.withLock {
            reads.append(service)
            return values["\(service)/\(account)"]
        }
    }
    func write(_ value: Data, service: String, account: String) throws {
        lock.withLock { values["\(service)/\(account)"] = value }
    }
    func delete(service: String, account: String) throws {
        lock.withLock { _ = values.removeValue(forKey: "\(service)/\(account)") }
    }
}

private actor StoreStandardSpeechInput: SpeechInput {
    private(set) var starts = 0
    func authorization() async -> SpeechAuthorization { .authorized }
    func requestAuthorization() async -> SpeechAuthorization { .authorized }
    func start() async throws -> AsyncThrowingStream<SpeechRecognitionUpdate, Error> {
        starts += 1
        return AsyncThrowingStream { $0.finish() }
    }
    func finish() async {}
    func cancel() async {}
}

private actor StoreStandardHandsFreeInput: HandsFreeInput {
    private(set) var authorizationRequests = 0
    func authorization() async -> SpeechAuthorization { authorizationRequests += 1; return .authorized }
    func requestAuthorization() async -> SpeechAuthorization { authorizationRequests += 1; return .authorized }
    func start() async throws -> AsyncThrowingStream<HandsFreeInputEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func finish() async {}
    func cancel() async {}
}

private actor StoreStandardAudioOutput: AudioOutput {
    func start(format: AudioFormat) async throws {}
    func append(_ pcm: Data) async throws -> AudioPlaybackReadiness { .ready }
    func finish() async throws {}
    func stop() async {}
    func pause() async {}
    func resume() async {}
    func playbackPosition() async -> TimeInterval? { nil }
}

private struct StoreStandardUnsafeError: LocalizedError {
    var errorDescription: String? { "wss://standard.example/api/ws?token=sentinel-secret" }
}
