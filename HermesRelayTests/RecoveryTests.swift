import Foundation
import XCTest
@testable import HermesRelayIOS

final class RecoveryTests: XCTestCase {
    @MainActor
    func testFailedSendPreservesDraftAndPersistsIt() async {
        let persistence = RecordingConversationPersistence()
        let client = RecoveryHermesSessionClient(mode: .disconnect)
        let store = ConversationStore(client: client, persistence: persistence)
        await store.connect()
        store.draft = "Do not lose this"

        await store.sendDraft()

        XCTAssertEqual(store.draft, "Do not lose this")
        XCTAssertEqual(store.unconfirmedTurnText, "Do not lose this")
        let saved = await persistence.lastSaved()
        XCTAssertEqual(saved?.draft, "Do not lose this")
    }

    @MainActor
    func testReconnectDoesNotReplayAnUnconfirmedTurn() async {
        let client = RecoveryHermesSessionClient(mode: .disconnect)
        let store = ConversationStore(client: client)
        await store.connect()

        await store.sendTurn(text: "Maybe sent")
        await store.connect()

        XCTAssertEqual(client.sentTurns, ["Maybe sent"])
        XCTAssertEqual(store.unconfirmedTurnText, "Maybe sent")
    }

    @MainActor
    func testCompletedTurnClearsTheUnconfirmedMarker() async {
        let client = RecoveryHermesSessionClient(mode: .disconnect)
        let store = ConversationStore(client: client)
        await store.connect()
        await store.sendTurn(text: "First attempt")

        client.mode = .complete
        await store.connect()
        await store.sendTurn(text: "Second attempt")

        XCTAssertEqual(client.sentTurns, ["First attempt", "Second attempt"])
        XCTAssertNil(store.unconfirmedTurnText)
    }

    @MainActor
    func testHomeRecoveryRestoresUncertaintyWithoutReplayingPrompt() async throws {
        let profileID = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000000")!
        let profile = try RelayProfile(
            id: profileID,
            endpoint: URL(string: "wss://legacy.example/session")!,
            clientID: "hermes-apple",
            deviceID: "apple-device",
            displayName: "Recovery Home"
        )
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesRelayIOS-HomeRecoveryReview-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: profileURL.deletingLastPathComponent()) }

        let configurationStore = RelayConfigurationStore(
            secureStore: HomeRecoverySecureValueStore(),
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
        let turn = HomeTurnBinding(
            conversationHandle: claim.conversationHandle,
            turnID: "turn-recovery",
            correlationID: "correlation-recovery"
        )
        let recovery = PersistedHomeRecovery(
            profileID: profileID,
            endpoint: claim.approvedRoute.endpoint,
            route: claim.approvedRoute.identity,
            householdBinding: claim.approvedRoute.householdBinding,
            conversationHandle: claim.conversationHandle,
            turnID: turn.turnID,
            correlationID: turn.correlationID,
            submissionAttemptID: UUID(uuidString: "DDDDDDDD-EEEE-FFFF-0000-111111111111"),
            resumeCursor: "cursor-recovery",
            deliveryState: .uncertain,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let persistence = HomeRecoveryConversationPersistence(
            conversation: PersistedConversation(
                messages: [TranscriptMessage(role: .user, text: "Uncertain Home prompt")],
                draft: "",
                unconfirmedTurnText: "Uncertain Home prompt",
                homeRecovery: recovery
            )
        )
        let client = FakeHomeBridgeSessionClient(claim: claim)
        let store = ConversationStore(
            configurationStore: configurationStore,
            persistence: persistence,
            homeClientFactory: FakeHomeBridgeSessionClientFactory(client: client),
            homeClaimProvider: StaticHomeConversationClaimProvider(claim: claim)
        )

        let configured = await store.loadConfiguredClient()
        XCTAssertTrue(configured)
        await store.loadPersistedConversation()
        XCTAssertEqual(store.homeTurnDeliveryState, .uncertain(turn))
        XCTAssertEqual(store.unconfirmedTurnText, "Uncertain Home prompt")
        await client.setNextOpenFailure(.reconnectRequired)

        await store.connect()

        XCTAssertTrue(store.connectionState.isConnected)
        XCTAssertTrue(store.homeBridgeState.isReady)
        XCTAssertEqual(store.homeTurnDeliveryState, .uncertain(turn))
        let reconnectCount = await client.reconnectCount
        XCTAssertEqual(reconnectCount, 1)
        let submittedTexts = await client.submittedTexts
        XCTAssertEqual(submittedTexts, [])
    }
}

private actor RecordingConversationPersistence: ConversationPersistence {
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

private actor HomeRecoveryConversationPersistence: ConversationPersistence {
    private let conversation: PersistedConversation

    init(conversation: PersistedConversation) {
        self.conversation = conversation
    }

    func load() async throws -> PersistedConversation {
        conversation
    }

    func save(_ conversation: PersistedConversation) async throws {}
}

private final class HomeRecoverySecureValueStore: SecureValueStore, @unchecked Sendable {
    func read(service: String, account: String) throws -> Data? { nil }
    func write(_ value: Data, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}

private final class RecoveryHermesSessionClient: HermesSessionClient, @unchecked Sendable {
    enum Mode {
        case disconnect
        case complete
    }

    var mode: Mode
    private(set) var sentTurns: [String] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func connect() async throws -> SessionMetadata {
        SessionMetadata(sessionID: "session-1", model: nil)
    }

    func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error> {
        sentTurns.append(text)
        let mode = mode
        return AsyncThrowingStream { continuation in
            switch mode {
            case .disconnect:
                continuation.finish(throwing: RelaySessionError.disconnected)
            case .complete:
                continuation.yield(.messageStart)
                continuation.yield(.textDelta("Confirmed"))
                continuation.yield(.turnComplete(turnID: "turn-1"))
                continuation.finish()
            }
        }
    }

    func disconnect() async {}
}
